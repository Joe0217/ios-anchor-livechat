import SwiftUI

/// 右下角浮标 —— 显示 sureGetAward 钻石数 + tap 跳 Task。对齐 H5 `van-floating-bubble`。
/// 可拖动：拖动到用户按下的位置，边界内 clamp。
struct LiveDataMoneyBag: View {
    let sureGetAward: Int
    let onTap: () -> Void

    /// 相对 GeometryReader 容器的位置（默认右下，按屏宽等比缩放对齐 H5）
    @State private var offset: CGSize?
    @State private var dragging: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            // H5 defaultX = viewWidth - 58*(viewWidth/375) - 16；defaultY = viewHeight - 200*(viewWidth/375)
            // 换算：以 375pt 屏宽为基准等比缩放；iOS geo.size 已是 pt 单位（H5 viewWidth 也是 pt）
            let baseScale = geo.size.width / 375
            // itemSize.height = Image 50 + spacing(-5) + Badge 20 ≈ 65pt（真实渲染高度）
            let itemSize = CGSize(width: 58, height: 65)
            let defaultOffset = CGSize(
                width: geo.size.width - (itemSize.width * baseScale) - 16,
                height: geo.size.height - (200 * baseScale)
            )
            let current = offset ?? defaultOffset
            let live = CGSize(
                width: current.width + dragging.width,
                height: current.height + dragging.height
            )

            bubble
                .offset(live)
                .gesture(
                    DragGesture()
                        .onChanged { value in dragging = value.translation }
                        .onEnded { value in
                            let candidate = CGSize(
                                width: current.width + value.translation.width,
                                height: current.height + value.translation.height
                            )
                            offset = clamp(candidate,
                                           within: geo.size,
                                           itemSize: itemSize,
                                           margin: 16)
                            dragging = .zero
                        }
                )
        }
    }

    private var bubble: some View {
        Button(action: onTap) {
            // H5 .moneyBag { background: none !important; } —— 无任何背景圆，直接显示 3D webp。
            // Badge 是浮标底部胶囊状钻石数徽章，粉→紫渐变（H5 line 397-406）。
            VStack(spacing: -5) {
                CDNAssetImage("moneyBag")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 50, height: 50)

                HStack(spacing: 4) {
                    CDNAssetImage("coins")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                    Text("\(sureGetAward)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(
                    Capsule().fill(
                        LinearGradient(colors: [Color(hex: 0xEF446F), Color(hex: 0xE12DDB)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                )
                .shadow(color: .black.opacity(0.43), radius: 2, y: -1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Money Bag")
    }

    private func clamp(_ pos: CGSize, within container: CGSize, itemSize: CGSize, margin: CGFloat) -> CGSize {
        let minX: CGFloat = margin
        let maxX = container.width - itemSize.width - margin
        let minY: CGFloat = margin + 44  // 避 nav bar
        let maxY = container.height - itemSize.height - margin
        return CGSize(
            width: min(max(minX, pos.width), maxX),
            height: min(max(minY, pos.height), maxY)
        )
    }
}
