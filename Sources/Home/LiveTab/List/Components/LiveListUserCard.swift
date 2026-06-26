import SwiftUI

/// 单张用户卡片：左侧圆形头像（带绿色在线点）+ 中部 [昵称 / 等级行 / 位置行] + 右侧动作按钮。
/// 字段对齐 H5 `views/home/components/list.vue` 模板。
struct LiveListUserCard: View {
    let anchor: LiveListAnchor

    var body: some View {
        // H-0：整 cell 包 NavigationLink 推入 UserProfileView。actionButton 用 .buttonStyle(.borderless)
        // 嵌套使其独立响应 tap 不冒泡到外层 NavigationLink（spec §5.3 + R-F9）。
        NavigationLink(value: UserProfileRoute.userId(anchor.userId)) {
            HStack(spacing: 12) {
                avatar
                infoColumn
                Spacer(minLength: 4)
                LiveListActionButton(action: .chat)
                    .buttonStyle(.borderless)
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
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// 圆形头像 + 右下绿色在线圆点。`icon` 走 AsyncImage；nil/失败回退占位渐变 + 系统人像。
    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            avatarImage
                .frame(width: Theme.Metric.liveListAvatarSize, height: Theme.Metric.liveListAvatarSize)
                .clipShape(Circle())

            Circle()
                .fill(Theme.Palette.liveListOnlineDot)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.3), lineWidth: 1.5))
                .padding(2)
        }
    }

    @ViewBuilder
    private var avatarImage: some View {
        if let icon = anchor.icon, let url = URL(string: icon) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    avatarPlaceholder
                }
            }
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0xE7B5C8), Color(hex: 0x6E3A4A)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Image(systemName: "person.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(anchor.nickname)
                .font(Theme.Typography.liveListUserName)
                .foregroundStyle(Theme.Palette.liveListUserName)
                .lineLimit(1)
                .truncationMode(.tail)

            // 等级 / VIP 行：userLevel != "0" 才显示 Lv 徽章；vipExpireTime > 当前才显示 VIP 徽章
            HStack(spacing: 4) {
                if anchor.hasLevelBadge {
                    Image("liveListLevelIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    Text("Lv.\(anchor.userLevel ?? "")")
                        .font(Theme.Typography.liveListMeta)
                        .foregroundStyle(Theme.Palette.liveListUserMeta)
                }
                if anchor.hasVipBadge {
                    Image("liveListVipBadge")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 14)
                        .accessibilityHidden(true)
                }
            }

            // 位置行
            if let country = anchor.country, !country.isEmpty {
                HStack(spacing: 4) {
                    Image("liveListLocation")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(country)
                        .font(Theme.Typography.liveListMeta)
                        .foregroundStyle(Theme.Palette.liveListLocationText)
                }
            }
        }
    }

    private var accessibilityText: String {
        var parts = [anchor.nickname]
        if anchor.hasLevelBadge, let lv = anchor.userLevel { parts.append("Lv.\(lv)") }
        if let c = anchor.country, !c.isEmpty { parts.append(c) }
        return parts.joined(separator: ", ")
    }
}
