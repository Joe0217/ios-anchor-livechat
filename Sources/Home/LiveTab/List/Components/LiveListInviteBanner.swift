import SwiftUI

/// "Invite friends" 邀请活动 banner。
/// 紫→粉渐变背景 + 黄色标题 + 白色副标题 + 右侧宝箱插画 + 底部轮播指示器。
/// 无宝箱切图，用 SF Symbol "shippingbox.fill" + emoji 占位，待接入活动图替换。
struct LiveListInviteBanner: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                leftCopy
                Spacer(minLength: 8)
                illustration
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            pageIndicator
                .padding(.bottom, 8)
        }
        .frame(height: Theme.Metric.liveListInviteHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.liveListInvite, style: .continuous)
                .fill(Theme.Gradients.liveListInviteBanner)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(L10n.liveListInviteTitle). \(L10n.liveListInviteSubtitle)")
    }

    private var leftCopy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.liveListInviteTitle)
                .font(Theme.Typography.liveListInviteTitle)
                .foregroundStyle(Theme.Palette.liveListInviteTitle)
                .lineLimit(1)
            Text(L10n.liveListInviteSubtitle)
                .font(Theme.Typography.liveListInviteSubtitle)
                .foregroundStyle(Theme.Palette.liveListInviteSubtitle)
                .lineLimit(1)
        }
    }

    /// 宝箱占位：SF Symbol + 闪光 emoji，待接入活动 banner 图后替换为 Image。
    private var illustration: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.yellow.opacity(0.4), Color.clear],
                        center: .center,
                        startRadius: 4,
                        endRadius: 50
                    )
                )
                .frame(width: 80, height: 80)
            Text("💎")
                .font(.system(size: 44))
        }
        .frame(width: 92, height: 72)
        .accessibilityHidden(true)
    }

    /// 底部 3 点轮播指示器（当前固定第 1 页选中，无真实分页）
    private var pageIndicator: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(index == 0 ? 1 : 0.4))
                    .frame(width: index == 0 ? 14 : 5, height: 4)
            }
        }
        .accessibilityHidden(true)
    }
}
