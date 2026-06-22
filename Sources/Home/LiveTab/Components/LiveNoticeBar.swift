import SwiftUI

/// 顶部礼物通知条：左侧头像 + 用户名 + 动作描述 + 右侧金币数字。
/// 紫粉横向渐变 + 玫红描边胶囊。
struct LiveNoticeBar: View {
    let data: LiveNoticeData

    var body: some View {
        HStack(spacing: 8) {
            avatarBubble
            HStack(spacing: 4) {
                Text(data.userName)
                    .foregroundStyle(Theme.Palette.liveNoticeUserGreen)
                Text(data.action)
                    .foregroundStyle(.white)
            }
            .font(Theme.Typography.liveNotice)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            Spacer(minLength: 6)
            amountTag
        }
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .frame(height: Theme.Metric.liveNoticeBarHeight)
        .background(
            Capsule()
                .fill(Theme.Gradients.liveNoticeBar)
        )
        .overlay(
            Capsule()
                .strokeBorder(Theme.Palette.liveNoticeBarBorder.opacity(0.6), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(data.userName) \(data.action) \(data.amount)")
    }

    private var avatarBubble: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0xC79988), Color(hex: 0x5E3D4D)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Image(systemName: "person.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(width: 32, height: 32)
        .overlay(
            Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1)
        )
    }

    private var amountTag: some View {
        HStack(spacing: 4) {
            Image(systemName: "diamond.fill")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(Theme.Palette.liveNoticeNumber)
            Text(data.amount)
                .font(Theme.Typography.liveNoticeNum)
                .foregroundStyle(Theme.Palette.liveNoticeNumber)
        }
    }
}
