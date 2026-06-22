import SwiftUI

/// 单张用户卡片：左侧圆形头像（带绿色在线点）+ 中部 [昵称 / 等级行 / 位置行] + 右侧动作按钮。
/// 卡片背景是深紫半透明圆角，浮在 LiveTab 顶部紫色背景上。
struct LiveListUserCard: View {
    let user: LiveListUser

    var body: some View {
        HStack(spacing: 12) {
            avatar
            infoColumn
            Spacer(minLength: 4)
            LiveListActionButton(action: user.action)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(height: Theme.Metric.liveListCardHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.liveListCard, style: .continuous)
                .fill(Theme.Palette.liveListCardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.liveListCard, style: .continuous)
                .strokeBorder(Theme.Palette.liveListCardBorder, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(user.name), \(user.levelText), \(user.location)")
    }

    /// 圆形头像 + 右下绿色在线圆点（占位渐变 + 系统人像，待接入用户接口替换）。
    /// 在线点用 padding 而非 offset 放在 trailing-bottom 内侧，确保 RTL（阿语）下自动镜像。
    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [user.avatarColorTop, user.avatarColorBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Image(systemName: "person.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: Theme.Metric.liveListAvatarSize, height: Theme.Metric.liveListAvatarSize)
            .clipShape(Circle())

            Circle()
                .fill(Theme.Palette.liveListOnlineDot)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.3), lineWidth: 1.5))
                .padding(2)
        }
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(user.name)
                .font(Theme.Typography.liveListUserName)
                .foregroundStyle(Theme.Palette.liveListUserName)
                .lineLimit(1)
                .truncationMode(.tail)

            // 等级行：小星等级图标 + VIP 徽章 + 等级文字
            HStack(spacing: 4) {
                Image("liveListLevelIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Image("liveListVipBadge")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 14)
                    .accessibilityHidden(true)
                Text(user.levelText)
                    .font(Theme.Typography.liveListMeta)
                    .foregroundStyle(Theme.Palette.liveListUserMeta)
            }

            // 位置行：pin + 国名
            HStack(spacing: 4) {
                Image("liveListLocation")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(user.location)
                    .font(Theme.Typography.liveListMeta)
                    .foregroundStyle(Theme.Palette.liveListLocationText)
            }
        }
    }
}
