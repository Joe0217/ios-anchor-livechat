# SwiftUI Button + `.plain` style + VStack/HStack cell 必配 `.contentShape(Rectangle())`

> 来源：K 里程碑 2026-07-02 用户反馈"Red Ribbon 图标很难点击"—— 4 处 cell（Sticker × / Sticker items / ParamIconRow Recover / ParamIconRow params）都缺 `.contentShape(Rectangle())`

## 规则

**任何** `Button + .buttonStyle(.plain) + VStack/HStack label`（尤其含 Circle/Image + Text 的图标 cell）**必须**在 label 最外层加 `.contentShape(Rectangle())`，否则热区仅覆盖内容 pixel（图形/文字），VStack 内部空白 + 边距不响应点击。

## Why

`.buttonStyle(.plain)` 不给 Button 加默认背景/hit region 扩展 —— Button 的 hit test 只对 label 内容的**实际渲染 pixel** 响应。VStack 只是布局容器，本身不是可点击 pixel；Circle stroke 是**空心**只有边线响应；Text 只在字符 pixel 响应。cell 里字符之间的空白、Circle 中心透明区、VStack 上下 padding 全部**不响应**。

用户看到：图标 + 标签视觉上像一个整体按钮，但**点标签下方 / Circle 中心 / 上下 padding 都不响应**，只有精确点在 Circle 边线或字符 pixel 上才触发 → 感受"很难点击"。

**具体错例**（K 里程碑真犯 4 次）：
```swift
Button {
    // ...
} label: {
    VStack(spacing: 4) {
        Circle()
            .stroke(...)  // 空心圆，只边线响应
            .frame(width: 44, height: 44)
            .overlay(Image(systemName: symbol)...)
        Text(label)
            .lineLimit(1)  // 只字符 pixel 响应
    }
    .frame(width: 54)   // ❌ 缺 .contentShape(Rectangle())
}
.buttonStyle(.plain)
```

**正例**：
```swift
Button {
    // ...
} label: {
    VStack(spacing: 4) {
        Circle().stroke(...).frame(width: 44, height: 44)
            .overlay(Image(systemName: symbol)...)
        Text(label).lineLimit(1)
    }
    .frame(width: 54)
    .contentShape(Rectangle())   // ✅ 整个 VStack 区域都是热区
}
.buttonStyle(.plain)
```

## How to apply

写任何 icon+label cell 时：

1. 用 `Button + .plain` 还是 `.onTapGesture`？—— 若走 Button，检查 label 是否 VStack/HStack 组合；若是，加 `.contentShape(Rectangle())`
2. 用 `.onTapGesture` 时也需要 `.contentShape(Rectangle())`（同样问题），但更常见于自定义 view 已知加
3. 视觉 QA：**测试用户在 cell 视觉边界外沿 1-2pt 处点击**是否响应；若不响应 → 缺 contentShape

## 适用范围

- ✅ 所有 icon+label 图标 cell（美颜参数 / 滤镜缩略图 / 贴纸 / 表情选择 / 头像 grid 等）
- ✅ 任何 `.buttonStyle(.plain)` + 组合容器 label
- ✅ Menu / ContextMenu / List row 里的自定义 cell

## 不适用

- Button label 是单一 Text/Image 且填满容器（默认整个 label 就是热区）
- 系统 style 的 Button（`.borderedProminent` / `.bordered` 等自带背景形状，本身就是热区）

## 类似规则组合

- 「`.frame(...)` 定尺寸容器 + 空 pixel = 死区」是 SwiftUI 通用陷阱，与 [swiftui-camera-preview.md](swiftui-camera-preview.md) §1 "switch case 内重复 View 用 if 承载" 是同类"SwiftUI 声明式与用户预期不符"问题
- [swiftui-keepalive-publisher-isolation.md](swiftui-keepalive-publisher-isolation.md) 处理"订阅串扰"，本规则处理"点击串扰"，同源都是 SwiftUI 声明式的隐性陷阱

## 历史教训

- **2026-07-02 K 里程碑**：4 处贴纸/参数 cell 全部缺 `.contentShape(Rectangle())`，用户真机反馈"很难点击"。同一 PR 内一次修 4 处 + 沉淀本规则。同时观察到用户容易把"很难点击"和"cell 视觉不清晰"混为一谈——**真根因是热区，不是视觉大小**。
