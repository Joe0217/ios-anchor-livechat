# SwiftUI keep-alive 架构下的 publisher 订阅隔离

> 来源：MainTabView keep-alive 改造（2026-06-25）暴露的反模式
> 范围：任何"view tree 永久持有但视觉切显隐"的容器

## 规则

**view 不可见时 publisher 触发 body 重算 = 性能浪费，必须收敛订阅粒度**。

具体三条：

1. **禁止在 keep-alive view 内 `@ObservedObject` 整个大单例 store**。
2. **禁止在 keep-alive view 内订阅 `objectWillChange` 通用信号**——一律改用细粒度派生 publisher。
3. **跨模块共享的 store 必须按业务关注点拆派生 bridge**，view 只订阅 bridge，不订阅 source。

## Why（具体反例 + 真实成本）

### 反例 1：`@ObservedObject` 整个大 store

```swift
struct LiveTabView: View {
    @ObservedObject private var anchorInfoStore = AnchorInfoStore.shared   // ❌
    // ...
}
```

`AnchorInfoStore` 是跨模块单例，含 `info` / `mine` / `followingCount` / `followersCount` / `friendsCount` / VIP 字段等 N 个 `@Published`。任一字段变化都触发 `objectWillChange` → `LiveTabView` body 重算。

**真实成本**：
- 用户在 Profile tab 关注/取消关注 → `followingCount` 变化 → 不可见的 `LiveTabView` body 重算 + 所有 `.onChange` 跑一遍
- keep-alive 架构（MainTabView ZStack opacity）下，不可见 view tree 永久持有，**没有 dismantle 兜底**
- 之前 `switch selection` 架构下 LiveTabView 切走会 dismantle，所以这个问题被掩盖；改 keep-alive 后才显形

### 反例 2：TabView(.page) 多 tag 预先创建 + view-level publisher

LiveTabView 内 TabView(.page) 4 个 tag（Live/List/Match/Circle）**全部预先创建**。
即使用户当前在 Live，Circle tag 的 `CircleView` 也在 view tree，`MomentFeedStore` 订阅活跃。
Moment feed 来了实时刷新通知 → 不可见的 `MomentView` body 重算。

### 反例 3：监听信号源而非业务相关性

```swift
.onChange(of: anchorInfoStore.hasLoadedTier) { _ in ... }
.onChange(of: anchorInfoStore.isSLevelAnchor) { _ in ... }
```

每个 store property 都是独立 `@Published`，但 view body 整体由 store.objectWillChange 触发重算 —— **`onChange` 排查是"什么字段变了"不是"是否要响应"**。

## How to apply

### 方案 A（首选）：派生 bridge ObservableObject

把 view 关心的派生 Bool / 值抽出一个轻 `ObservableObject`：

```swift
@MainActor
final class AnchorTierBridge: ObservableObject {
    @Published private(set) var hasLoadedTier: Bool = false
    @Published private(set) var isSLevelAnchor: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init(source: AnchorInfoStore = .shared) {
        // 仅监听 view 关心的派生值，去重后转发
        source.$info
            .combineLatest(source.$mine)
            .map { ($0 != nil) || ($1?.level != nil) }
            .removeDuplicates()
            .assign(to: &$hasLoadedTier)

        source.$info
            .combineLatest(source.$mine)
            .map { AnchorTierClassifier.isSLevel(info: $0, mine: $1) }
            .removeDuplicates()
            .assign(to: &$isSLevelAnchor)
    }
}
```

view 只订阅 bridge：

```swift
@StateObject private var tierBridge = AnchorTierBridge()
```

`followingCount/followersCount/friendsCount` 变化时 source 的 publisher 仍 fire，但
bridge 的 `removeDuplicates` 守门 —— 派生值不变就不 emit，view body 不重算。

### 方案 B（更激进）：active 时才订阅

通过 `@Environment` 注入 `isActive`，store 据此决定订阅/取消：

```swift
@MainActor
final class HomeStreamBridge: ObservableObject {
    @Published private(set) var data: SomeData?
    private var cancellable: AnyCancellable?

    func activate() {
        guard cancellable == nil else { return }
        cancellable = source.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.data = $0 }
    }

    func deactivate() {
        cancellable?.cancel()
        cancellable = nil
    }
}
```

view 层：

```swift
@Environment(\.isHomeTabActive) private var isActive

.onChange(of: isActive) { active in
    if active { bridge.activate() } else { bridge.deactivate() }
}
```

用于"不可见时连数据都不需要保留"的场景。**不适合 keep-alive 体验依赖的数据**（如朋友圈滚动位置）。

### 方案 C：拆 sub-stores（架构整改）

`AnchorInfoStore` 当前承担 Profile / Home / Live / Call 多模块需求，违反 SRP。
拆 `AnchorTierStore` / `AnchorSocialCountStore` / `AnchorVIPStore` 三个独立 store，
各 view 只订阅相关 sub-store。改动量大但治本。

## 自检清单

写或改 keep-alive 容器内的 view 时跑一遍：

- [ ] view 是否被 ZStack opacity / TabView(.page) / 0-height 容器永久持有？
- [ ] view 内是否 `@ObservedObject` / `@StateObject` 大单例 store？→ 抽 bridge
- [ ] view 监听的 `@Published` 字段是否大部分与本 view 业务无关？→ 抽派生
- [ ] view 内多个 `.onChange` 是否监听同一 store 的不同字段？→ 合并为单个派生 `@Published`
- [ ] keep-alive 不依赖该 store 数据（如"切走再回来不需要保留"）？→ 用方案 B 不可见时退订

## 适用场景

- **MainTabView**：4 个 tab 通过 ZStack opacity keep-alive
- **TabView(.page)**：多 tag 预先创建（如 LiveTabView 的 4 outer tab / CircleView 的 3 sub-tab）
- **Onboarding / 引导页**：保留页面状态做向前向后切换
- **直播 / 派对房 PIP**：主预览 + 小窗同时持有，inactive 一侧不该响应 publisher

## 不适用场景

- view 与 store 一对一、生命周期一致（store 死则 view 死） —— 标准 SwiftUI 模式
- 单页 app，无任何 keep-alive 容器
- 临时弹窗 / sheet（dismiss 时整体 dismantle）

## 与既有规则关联

- [.claude/rules/swiftui-camera-preview.md](swiftui-camera-preview.md) 规则 1（switch case 内重复子 View 必须用 if 链承载）—— 同源问题：view identity 稳定性。本规则补"keep-alive 后订阅同样要稳定"。
- [.claude/rules/async-state-fallback.md](async-state-fallback.md) —— 派生异步 view 的兜底设计。本规则补"派生订阅的过滤设计"。
- [CLAUDE.md](../../CLAUDE.md) "副作用全收敛进 Store/Controller" —— 本规则补"Store 自身的订阅也要分级隔离"。

## 历史决策

- **2026-06-25 MainTabView keep-alive 改造**：把 Home/Messages 改 ZStack opacity 永久持有，朋友圈滚动位置不丢；附带暴露此 publisher 串扰问题（review 报告 [P2-A](../../docs/plan/代码审查报告-202606252040.md)），列入 J 里程碑性能批
- **未来扩展**：直播 PIP（主预览 + 小窗）、派对房多座位 view 共享 PartyStore 时同样适用
