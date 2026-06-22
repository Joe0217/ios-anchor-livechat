import SwiftUI

/// 在线开关（纯代码绘制，不依赖切图）。
/// 开态：粉紫渐变胶囊、滑块在 trailing、文字 "Online"；
/// 关态：灰紫底、滑块在 leading、文字 "Offline"。状态切换带弹簧滑动动画。
///
/// 宽度自适应：文字按内容自然撑开（防截断），滑块侧预留固定区，
/// 胶囊随文字长度伸缩 —— 适配不同语言（en/ar/tr）文案宽度差异。
/// 用语义 leading/trailing，RTL 自动镜像。
struct OnlineToggleView: View {
    @Binding var isOn: Bool

    private let height: CGFloat = 30
    private var knobDiameter: CGFloat { height - 6 }
    /// 滑块预留区（直径 + 内边距 + 与文字的留白）
    private var knobZone: CGFloat { height + 4 }
    /// 文字外侧（远离滑块一侧）内边距
    private let textOuterPadding: CGFloat = 10

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                isOn.toggle()
            }
        } label: {
            Text(isOn ? L10n.workOnline : L10n.workOffline)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)   // 按文字内容撑开，绝不截断
                // 滑块侧预留 knobZone，文字侧留 textOuterPadding —— 总宽随文字自适应
                .padding(.leading, isOn ? textOuterPadding : knobZone)
                .padding(.trailing, isOn ? knobZone : textOuterPadding)
                .frame(height: height)
                .background(
                    Capsule().fill(isOn ? AnyShapeStyle(Theme.Gradients.onlineToggleOn)
                                        : AnyShapeStyle(Theme.Palette.onlineToggleOff))
                )
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: knobDiameter, height: knobDiameter)
                        .padding(3)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.workOnline)
        .accessibilityValue(isOn ? L10n.workOnlineOn : L10n.workOnlineOff)
    }
}

#Preview {
    struct Demo: View {
        @State private var on = true
        var body: some View {
            VStack(spacing: 20) {
                OnlineToggleView(isOn: $on)
                OnlineToggleView(isOn: .constant(false))
            }
            .padding()
            .background(Theme.Palette.screenBackground)
        }
    }
    return Demo()
}
