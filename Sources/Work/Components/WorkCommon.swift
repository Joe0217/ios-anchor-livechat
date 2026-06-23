import SwiftUI

/// 描边胶囊（文字 + 右尖角），用于 "Detail >" / "Withdrawal >"。
struct OutlineChevronPill: View {
    let title: String

    var body: some View {
        HStack(spacing: 3) {
            Text(title)
            // 使用 chevron.forward 而非 chevron.right：SF Symbols 的 .forward 会在 RTL 区域（如 ar）自动镜像
            Image(systemName: "chevron.forward")
                .font(.system(size: 9, weight: .semibold))
        }
        .font(Theme.Typography.pill)
        .foregroundStyle(Theme.Palette.outlinePill)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(
            Capsule().stroke(Theme.Palette.outlinePill.opacity(0.6), lineWidth: 1)
        )
    }
}

/// 卡片表面修饰：填充 cardFill + 圆角，可选内边距。
private struct CardSurface: ViewModifier {
    let radius: CGFloat
    let padding: CGFloat?

    func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .background(Theme.Palette.cardFill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    /// 应用统一卡片表面。padding 为 nil 时不加内边距（由调用方控制）。
    func cardSurface(radius: CGFloat = Theme.Radius.bigCard, padding: CGFloat? = nil) -> some View {
        modifier(CardSurface(radius: radius, padding: padding))
    }
}
