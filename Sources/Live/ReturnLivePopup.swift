import SwiftUI

/// 通话结束回直播中央弹窗（对齐 H5 `anchor-livechat-h5/src/views/liveSetting/components/returnLivePopup.vue`）。
///
/// **触发**：`LiveStore.isWaitingReturnLive == true` 且 `returnLiveCountdown > 0`（由 `LiveRoomView.callAndReturnLiveOverlays` 判定显隐）。
///
/// **UI 结构**：
/// - 蒙层：黑色 65% 半透明（对齐 H5 CThemePopup）
/// - 中央卡片：暗紫黑背景 + RoundedRect 14
/// - 上部：80pt 旋转圆环 + 中央大数字（40pt monospaced）
/// - 中部：文案 "X seconds later it will automatically return to live"
/// - 下部：粉色胶囊按钮 "Return to live" → 调 `LiveStore.returnLiveNow()` 立刻回直播
/// - 蒙层屏蔽底层交互（不可 tap 关）
struct ReturnLivePopup: View {
    let countdown: Int
    let onReturn: () -> Void

    @State private var rotationAngle: Double = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [.pink, Color.purple.opacity(0.6), .pink],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .frame(width: 80, height: 80)
                        .rotationEffect(.degrees(rotationAngle))
                    Text("\(countdown)")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .accessibilityHidden(true)
                }
                .padding(.top, 32)
                .onAppear {
                    withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                        rotationAngle = 360
                    }
                }

                Text(String(format: L10n.liveReturnAutoFormat, countdown))
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)

                Button(action: onReturn) {
                    Text(L10n.liveReturnButton)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 1.0, green: 0.10, blue: 0.65),
                                         Color(red: 1.0, green: 0.43, blue: 0.61)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: Capsule()
                        )
                }
                .accessibilityLabel(L10n.liveReturnButton)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(width: 320)
            .background(Color(red: 0.11, green: 0.06, blue: 0.13).opacity(0.95),
                        in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(String(format: L10n.liveReturnAutoFormat, countdown)))
        }
        .contentShape(Rectangle())
        .onTapGesture {}   // 屏蔽底层 tap（对齐 H5 close-on-click-overlay=false）
    }
}
