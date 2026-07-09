import SwiftUI

/// H-3 钻石领取弹窗（Batch 6.3.1，对齐 H5 `diaReceivePop.vue` + 设计稿 `钻石领取弹窗.png`）。
///
/// **触发**：主播进入 chat 页时 `ReplyPointsStore.beginSession` → auto-claim 所有 `.claimable` 节点 →
/// 累加 `pendingClaimDiamond` → view 层订阅显示本弹窗。用户 tap `Get` 清空。
///
/// **视觉**（对齐设计稿）：
/// - 圆角紫色卡片（gradient `#3800A0 → #5300A1`）
/// - 顶部标题 "Congratulations"（20pt bold）
/// - 副标题 "Unlocked the Achievement"（14pt）
/// - "Received {N} Diamonds"（16pt medium）
/// - Get 按钮（紫粉渐变 pill）
///
/// **背后逻辑**：view 层 overlay 挂 ZStack 顶层，遮罩 tap 也可 dismiss（`onDismiss`）。
struct DiaReceivePopup: View {
    let diamondCount: Int
    let onGet: () -> Void

    var body: some View {
        ZStack {
            // 遮罩
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { onGet() }

            // 卡片
            card
        }
    }

    private var card: some View {
        VStack(spacing: 16) {
            Text("Congratulations")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 24)

            Text("Unlocked the Achievement")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.8))

            HStack(spacing: 6) {
                Text("Received")
                Text("\(diamondCount)")
                    .foregroundStyle(Color(hex: 0xFEB74C))
                Text("Diamonds")
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white)

            getButton
                .padding(.top, 8)
                .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
        .frame(width: 300)
        .background(
            LinearGradient(colors: [Color(hex: 0x3800A0), Color(hex: 0x5300A1)],
                           startPoint: .bottom, endPoint: .top),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private var getButton: some View {
        Button(action: onGet) {
            Text("Get")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    LinearGradient(colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                                   startPoint: .leading, endPoint: .trailing),
                    in: Capsule()
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Get diamonds")
    }
}
