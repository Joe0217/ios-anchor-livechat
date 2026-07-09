# SwiftUI keep-alive 架构下的 publisher 订阅隔离

> 来源：MainTabView keep-alive 改造（2026-06-25）暴露的反模式
> 范围：任何"view tree 永久持有但视觉切显隐"的容器

## 规则

**view 不可见时 publisher 触发 body 重算 = 性能浪费，必须收敛订阅粒度**。

三条：

1. **禁止在 keep-alive view 内 `@ObservedObject` 整个大单例 store**
2. **禁止在 keep-alive view 内订阅 `objectWillChange` 通用信号**——改用细粒度派生 publisher
3. **跨模块共享的 store 必须按业务关注点拆派生 bridge**，view 只订阅 bridge，不订阅 source

## Why

反例：`@ObservedObject private var anchorInfoStore = AnchorInfoStore.shared` —— 
store 含 `info` / `mine` / `followingCount` / `followersCount` / VIP 等 N 个
`@Published` 字段，任一变化都触发本 view body 重算。keep-alive 架构（MainTabView
ZStack opacity）下不可见 view tree 永久持有，**没有 dismantle 兜底**——之前
`switch selection` 架构下 LiveTabView 切走会 dismantle，问题被掩盖，改 keep-alive
后才显形。

同类反例：`TabView(.page)` 多 tag 预先创建（LiveTabView 4 tag Live/List/Match/Circle
全部提前 init），不可见 view 内的 store 订阅仍活跃。

## How to apply

### 方案 A（首选）：派生 bridge ObservableObject

view 关心的派生值抽出轻 `ObservableObject`，`removeDuplicates` 守门：

```swift
@MainActor
final class AnchorTierBridge: ObservableObject {
    @Published private(set) var hasLoadedTier: Bool = false
    @Published private(set) var isSLevelAnchor: Bool = false

    init(source: AnchorInfoStore = .shared) {
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

view 只订阅 bridge：`@StateObject private var tierBridge = AnchorTierBridge()`。
无关字段变化时 source publisher fire，但 bridge 的 removeDuplicates 拦截，
view body 不重算。

### 方案 B：active 时才订阅（更激进）

通过 `@Environment` 注入 `isActive`，store 据此 activate/deactivate：

```swift
@MainActor
final class HomeStreamBridge: ObservableObject {
    @Published private(set) var data: SomeData?
    private var cancellable: AnyCancellable?

    func activate() {
        guard cancellable == nil else { return }
        cancellable = source.publisher.sink { [weak self] in self?.data = $0 }
    }
    func deactivate() { cancellable?.cancel(); cancellable = nil }
}

// view 层
@Environment(\.isHomeTabActive) private var isActive
.onChange(of: isActive) { active in
    active ? bridge.activate() : bridge.deactivate()
}
```

用于"不可见时连数据都不需保留"的场景。**不适合 keep-alive 体验依赖数据**（如
朋友圈滚动位置）。

### 方案 C：拆 sub-stores（治本，改动大）

大 store 违反 SRP → 拆多个专用 sub-store，各 view 只订阅相关一个。适合长期
架构整改。

## 自检清单

写或改 keep-alive 容器内 view 时：

- [ ] view 是否被 ZStack opacity / TabView(.page) / 0-height 容器永久持有？
- [ ] view 内是否 `@ObservedObject` / `@StateObject` 大单例 store？→ 抽 bridge
- [ ] view 监听的 `@Published` 字段大部分与本 view 业务无关？→ 抽派生
- [ ] view 内多个 `.onChange` 监听同一 store 不同字段？→ 合并为单个派生 `@Published`
- [ ] keep-alive 不依赖该 store 数据？→ 方案 B 不可见时退订

## 适用场景

- **MainTabView**：4 tab 通过 ZStack opacity keep-alive
- **TabView(.page)**：多 tag 预先创建（LiveTabView 4 outer tab / CircleView 3 sub-tab）
- **直播 / 派对房 PIP**：主预览 + 小窗同持，inactive 一侧不该响应 publisher

## 不适用

- view 与 store 一对一、生命周期一致（标准 SwiftUI 模式）
- 单页 app 无任何 keep-alive 容器
- 临时弹窗 / sheet（dismiss 整体 dismantle）

## 与既有规则关联

- [swiftui-camera-preview.md](swiftui-camera-preview.md) §1：view identity 稳定性
- [async-state-fallback.md](async-state-fallback.md)：派生异步 view 的兜底设计
- CLAUDE.md "副作用全收敛进 Store/Controller"：本规则补"Store 自身订阅也要分级"
