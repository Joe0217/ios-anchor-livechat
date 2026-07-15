import SwiftUI

/// 统一 sheet 背景色 —— 与 CommonGiftPanel 一致的 3 色渐变（顶紫→中紫→近黑）。
///
/// 用法：
/// ```swift
/// .sheet(isPresented: $show) {
///     SomeSheetContent()
///         .giftPanelSheetBackground()
///         .presentationDetents([.medium])
/// }
/// ```
///
/// 例外场景（**不**应挂）：
/// - PK 相关 sheet（PKArenaView / PKInviteSheet / LiveRoomView 的 PK Invite / PKDebug）
/// - 榜单类 sheet（LiveRoomTopPopups 的 Contribution / Rank / UserWeeklyRank；LiveResultView 的 giftersSheet）
/// - CommonGiftPanel 自身（内部已铺同款渐变）
///
/// 实现分层：
/// - iOS 16.4+ 走 `.presentationBackground(_:)` —— 系统级替换 sheet material，无额外 view 层，性能最佳
/// - iOS 16.0–16.3 fallback `.background { ... }` —— 无 `.presentationBackground` API，铺在 content root 底下
extension View {
    @ViewBuilder
    func giftPanelSheetBackground() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationBackground {
                Theme.Gradients.livePageBackground
                    .ignoresSafeArea()
            }
        } else {
            self.background {
                Theme.Gradients.livePageBackground
                    .ignoresSafeArea()
            }
        }
    }
}

/// sheet content 内容高度自适应 —— 用 GeometryReader 测量真实内容高度，动态设 `.presentationDetents([.height(...)])`。
///
/// 用法（替代固定 `.medium`）：
/// ```swift
/// .sheet(isPresented: $show) {
///     SomeSheetContent()
///         .giftPanelSheetBackground()
///         .selfSizingSheetHeight()   // 内容有多高 sheet 就多高
/// }
/// ```
///
/// - `minHeight` / `maxHeight` 是**安全上下界**，首次呈现 measure 前用 `minHeight` 兜底；measure 完毕后动态设 detent。
/// - 用于 role/内容动态变化的 sheet（如 PartyRoomToolsSheet 按 role 显示不同 items 数）。
extension View {
    func selfSizingSheetHeight(
        minHeight: CGFloat = 200,
        maxHeight: CGFloat = 700
    ) -> some View {
        modifier(SelfSizingSheetHeightModifier(minHeight: minHeight, maxHeight: maxHeight))
    }
}

private struct SelfSizingSheetHeightModifier: ViewModifier {
    let minHeight: CGFloat
    let maxHeight: CGFloat
    @State private var measuredHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: SheetContentHeightKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(SheetContentHeightKey.self) { newValue in
                if newValue > 0 {
                    measuredHeight = min(max(newValue, minHeight), maxHeight)
                }
            }
            .presentationDetents([.height(measuredHeight > 0 ? measuredHeight : minHeight)])
    }
}

private struct SheetContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
