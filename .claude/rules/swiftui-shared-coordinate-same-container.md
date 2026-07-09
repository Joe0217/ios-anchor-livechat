# SwiftUI 需 pixel 级共坐标系的 view 必须放同一 layout container

> 来源：2026-07-07 PK 中本端 CameraPreview 与对方 PKOppositeContainer 齐平修复，前 4 轮补丁全下游打补丁失败，第 5 轮架构级把两个 view 放到同一 HStack 直接兄弟才根治

## 规则

**两个 view 元素必须严格共坐标系时（同 y / 同 x / 严格并排 / 尺寸联动），必须放在同一 layout container**（同 HStack / VStack / ZStack / Grid），**禁止**跨 GeometryReader / 跨独立子 view 分离。

## Why

SwiftUI 里两个独立 GeometryReader（或两个 sibling 顶层 view）**无法保证 pixel 级共坐标系**，即使名义上都 "全屏 + `.ignoresSafeArea()`"：

1. **modifier wrapper 引入 layout 中间层**：`.transition(.opacity)` / `.id(...)` / `.animation` 等 modifier 会引入 SwiftUI 内部 wrapper container，影响 sibling 布局
2. **layout pass 顺序不保证**：两个 sibling GR 各自 layout pass，SwiftUI 不保证按同序 / 同基准执行
3. **safe area / keyboard 差异**：内层与外层 `.ignoresSafeArea(...)` 参数不同会导致 GR.size 偏差（top safe area ≈ 47pt / bottom ≈ 34pt / keyboard 变化）
4. **ZStack 对齐**：ZStack 各子 view 独立布局，alignment 只影响子 view 与 ZStack container 的相对位置，不影响子 view **相互**位置

只有放同一 layout container 里的 sibling（同 HStack/VStack 直接子），SwiftUI 才**明确保证**它们共坐标系。

## 反例（本会话 2026-07-07 真犯 5 次才修）

```swift
// LiveRoomView 顶层 ZStack:
ZStack {
    Theme.Palette.liveBottomDark.ignoresSafeArea()
    if authorized {
        if isPKActive {
            GeometryReader { geo in         // ← GR #1
                VStack {
                    Spacer().frame(height: topOffset)
                    HStack {
                        CameraPreview()       // ← 本端视频
                        Spacer().frame(width: half)  // 右半留给 PKArenaView
                    }
                }
            }.ignoresSafeArea()
        }
    }
    if isPKActive {
        PKArenaView(...)                    // ← 内部有 GR #2 放对方 canvas
            .id("pkArena")
            .ignoresSafeArea()
            .transition(.opacity)           // ← wrapper 影响 layout
    }
}
```

结果：CameraPreview（GR#1 内）和 PKOppositeContainer（GR#2 内）**看起来都是"全屏起点 + Spacer(topOffset)"**，但真机上位置总差几十 pt。

失败补丁尝试（每次都以为找到根因，实际都是下游）：
- 补丁 1：修 PKOppositeContainer container + AutoLayout → 消除 SDK subview frame 陈旧问题（真实但非根因）
- 补丁 2：`.ignoresSafeArea(.keyboard)` → `.ignoresSafeArea()` → 消除 47pt 偏移（真实但非根因）
- 补丁 3：padding / topOffset 微调 → 缩小到 4pt（下游微调，非根因）
- 补丁 4-5：**架构级根治**——把 PKOppositeContainer 从 PKArenaView 移出，与 CameraPreview 放同一 HStack 直接兄弟

## 正例

```swift
GeometryReader { geo in
    VStack {
        Spacer().frame(height: topOffset)
        HStack(spacing: 0) {
            CameraPreview()
                .frame(width: geo.size.width / 2, height: videoHeight)
                .clipped()
            PKOppositeContainer(view: agora.oppositeRemoteView)  // ← 同 HStack 兄弟
                .frame(width: geo.size.width / 2, height: videoHeight)
                .clipped()
        }
    }
}
.ignoresSafeArea()
```

同 HStack 直接兄弟 → 严格共坐标系，SwiftUI 保证同一 y、同一 videoHeight → **100% 齐平**。

## How to apply

**设计时** —— 决定 UI tree 结构前问自己：
- [ ] 这两个 view 元素是否需要 **像素级严格共坐标系**（同一 y 起点 / 同一尺寸 / 严格并排 / 位置耦合）？
- [ ] 如是 → 它们必须在同一 layout container（HStack/VStack/ZStack/Grid）作**直接兄弟**
- [ ] 如否（如"顶部装饰" overlay 到 "视频区" 上方，允许几 pt 视觉容差）→ 可分独立子 view / 独立 GR

**调 bug 时** —— 遇到"位置对不齐 / 尺寸不同步"类 bug，**第 1 步**（不是调 padding）：
- [ ] Grep view hierarchy，看两个元素**是否在同一 layout container**
- [ ] 如否 → **架构级重构**先，才考虑下游 modifier / padding 调整
- [ ] 如是 → 才可以下游查 modifier / padding / frame constraint 差异

**Root cause 上溯**（对齐 [root-cause-investigation.md](root-cause-investigation.md) §2）：
- 下游 2 次修 padding / safe area / modifier 失败 → **强制上溯查 layout container 结构**
- 不要被"部分改善"（错位 47pt → 4pt）骗过 —— 只要错位仍存在，就是**架构性问题**未根治

## 适用场景

- ✅ PK 分屏视频（本端 + 对方必须严格并排等高）—— 本次真犯
- ✅ 派对房多座位视频位（seat 1-9 网格布局，尺寸必须严格一致）
- ✅ 通话中本端 PIP + 远端视频（PIP overlay 位置依赖远端 frame）—— 但 PIP 是 overlay 而非兄弟，是**依附**关系而非共坐标系
- ✅ 底部工具栏多个按钮（等宽等高严格并排）
- ✅ 顶部徽章 row（Task / Rank / Roulette 严格并排）

## 不适用场景

- overlay 关系（progressBar overlay 视频顶部）—— 允许几 pt 视觉偏差，可独立 GR
- 完全独立的两个 UI 区域（无坐标耦合）
- 只需要视觉上"大概"对齐（不要求 pixel 级）

## 与既有规则关联

- [swiftui-camera-preview.md](swiftui-camera-preview.md) §1 "switch case 重复子 View 用 if 承载" —— 同源"view identity / 布局稳定性"
- [swiftui-fullscreencover-hoist.md](swiftui-fullscreencover-hoist.md) "modal 必须 hoist 到唯一容器" —— 同源"独立子 view 分离带来问题"
- [swiftui-keepalive-publisher-isolation.md](swiftui-keepalive-publisher-isolation.md) —— 同源"tree 结构决定行为"
- [root-cause-investigation.md](root-cause-investigation.md) §2 "下游 2 次补丁失败强制上溯" —— 本 rule 是"上溯到什么层次"的具体指引

## 历史教训

- **2026-07-07 PK 对方视频齐平 5 次才修好**：本 rule 起源。前 4 轮补丁全在下游（SDK subview / safe area / padding），第 5 轮架构级把两 view 放同一 HStack 才根治。教训：`一开始就该问"两个 view 是否共容器"`，不要等到"改了 5-6 次"才想到架构层
