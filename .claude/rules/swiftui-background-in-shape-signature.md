# SwiftUI `.background(_:in:)` 只吃 ShapeStyle，不吃 `Group { if...else View }`

> 来源：2026-07-09 会话同一 build 里 LanguagePickerSheet + RewardProgressView 两处同错——都是 `.background(Group { if...else }, in: shape)` 报 "No exact matches in call to instance method 'background'"

## 规则

**要"某个形状 + 条件填充"效果**，两条路二选一，**不能混**：

### ❌ 反例（本次两文件都犯）
```swift
.background(
    Group {
        if selected {
            LinearGradient(...)
        } else {
            Color.gray.opacity(0.15)
        }
    },
    in: Capsule()
)
```

第一个参数期望 `ShapeStyle`（`Color` / `LinearGradient` / `Material` 等），`Group { if...else }` 是 `View` **不满足**。iOS 17 起 API 更严 → 报 `No exact matches`。

### ✅ 正例 A（推荐）：view-based `.background { shape.fill(...) }`
```swift
.background {
    if selected {
        Capsule().fill(LinearGradient(...))
    } else {
        Capsule().fill(Color.gray.opacity(0.15))
    }
}
```

条件在 shape 层：每个分支返回**已填充的完整 Shape View**，无 `in:` 参数需要。

### ✅ 正例 B：用 `AnyShapeStyle` 擦除条件类型
```swift
.background(
    selected ? AnyShapeStyle(LinearGradient(...)) : AnyShapeStyle(Color.gray.opacity(0.15)),
    in: Capsule()
)
```

保留 `.background(_:in:)` 签名，用类型擦除让条件表达式合法。iOS 16+ 支持。

## How to apply

写 `.background(...)` 前先判断：
- [ ] 我要传的第一个参数是 **View**（含 Group / if-else / 复杂 view tree）？→ 用**正例 A**（view-based `.background { }`）
- [ ] 我要传的第一个参数是**单个 ShapeStyle**（Color / LinearGradient / Material）？→ 可用 `.background(style, in: shape)`
- [ ] 要条件切 ShapeStyle？→ 用**正例 B** AnyShapeStyle 或转成正例 A

**遇报错 `No exact matches in call to instance method 'background'`**：99% 是 signature 匹配问题；grep 全工程同款用法一起改，避免一次报一次改：
```bash
grep -rn "\.background(" Sources/ | grep -A2 ", in:"
```

## Why

SwiftUI 有多个 `.background` overload，`.background(_:in:)` 明确要求 ShapeStyle：
```swift
// 期望 ShapeStyle
func background<S: ShapeStyle, T: Shape>(_ style: S, in shape: T) -> some View
// 期望 View（无 in: 参数）
func background<V: View>(_ content: V, alignment: Alignment) -> some View
// closure 版
func background<V: View>(@ViewBuilder content: () -> V) -> some View
```

iOS 16 编译器对 `Group { if...else }` overload 匹配偶尔糊过去（走到 view 版），iOS 17 SDK 收紧后彻底不匹配 `.background(_:in:)`。

## 与既有 rule 关联

- [swiftui-button-plain-hitarea.md](swiftui-button-plain-hitarea.md) —— 同源"SwiftUI 声明式陷阱系列"
- [swiftui-camera-preview.md](swiftui-camera-preview.md) §1 —— view identity / API 签名精确性
