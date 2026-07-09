import SwiftUI

/// 抽屉弹窗（`.sheet`）顶部内容间距 —— 用户诉求：无 NavigationBar/title 的 sheet 顶部内容
/// 与 sheet 边缘贴太近，统一在 sheet content root view 上挂 `.sheetTopInset()`。
///
/// **默认 20pt**（2026-07-09 v2：用户从 10pt 调至 20pt；11 处调用点无 override 全部随默认走）。
///
/// **实现**：`safeAreaInset(edge: .top)` 而非 `padding(.top)` —— 关键差异：
/// - `safeAreaInset` 只影响遵循 safe area 的 subview，`ignoresSafeArea` 的背景层（gradient / 铺色）**不受影响**
/// - `padding.top` 会缩小整个 view frame → 背景层顶部露出空白 sheet 默认色，视觉不对
///
/// **不需要挂**的场景：sheet content 顶部已有 NavigationBar / navigationTitle（系统 title 与内容
/// 之间天然有间距，再加会 double inset 露出多余空白）。
///
/// 使用：
/// ```swift
/// .sheet(isPresented: $show) {
///     MyPanel().sheetTopInset()   // ✅ 挂 content root
/// }
/// ```
extension View {
    func sheetTopInset(_ pt: CGFloat = 20) -> some View {
        self.safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: pt)
        }
    }
}
