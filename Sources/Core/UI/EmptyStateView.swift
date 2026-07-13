import SwiftUI

/// 全 app 统一的"空态"占位视图。
///
/// 图标走 `Assets.xcassets/EmptyStatePlaceholder.imageset`，文案默认 `L10n.commonNoContent`。
/// 调用方按场景包裹 Spacer / frame / padding；本视图只负责 icon + text 组合。
struct EmptyStateView: View {
    enum Style {
        /// 大图标 + 文字，默认 icon 120pt（列表 / 网格 / 全屏 sheet 场景）
        case full
        /// 中等图标 + 文字，icon 80pt（半屏 sheet / tab 内嵌）
        case compact
        /// 仅文字（横向 marquee / 单行内嵌，icon 会破坏布局的场景）
        case textOnly
    }

    var style: Style = .full
    var text: String = L10n.commonNoContent
    var textColor: Color = .white.opacity(0.6)
    var textFont: Font = .system(size: 14)

    var body: some View {
        VStack(spacing: 12) {
            if let size = iconSize {
                Image("EmptyStatePlaceholder")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(textFont)
                .foregroundStyle(textColor)
                .multilineTextAlignment(.center)
        }
    }

    private var iconSize: CGFloat? {
        switch style {
        case .full: return 140
        case .compact: return 90
        case .textOnly: return nil
        }
    }
}

#if DEBUG
struct EmptyStateView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 40) {
            EmptyStateView()
            EmptyStateView(style: .compact)
            EmptyStateView(style: .textOnly)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
#endif
