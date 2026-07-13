import SwiftUI

/// Party 房间顶部主播信息条（对齐设计稿 2026-07-11）。
///
/// 视觉三段：
/// - 左：奖杯装饰 + 头像 + 名字 + ID + 关注按钮
/// - 右：公告 / 分享 / 房管 / 更多 4 个白线图标
/// - 下行：奖杯 + 收益数字 + chevron; 人数 icon + 观众数 + chevron
///
/// 参数注入 pattern（对齐 [swiftui-keepalive-publisher-isolation]）——不订阅 store。
/// 事件通过 closure 上抛，避免子 view 反向依赖顶层状态机。
struct PartyRoomAnchorBar: View {
    let roomName: String
    let roomId: String
    let anchorAvatarURL: String?
    let heatText: String
    let viewerCountText: String
    let isFollowing: Bool
    /// v3：自己的房间（房主本人）不显示关注按钮（对齐 H5 用户端 index.vue 同 owner 隐藏 follow）
    let isSelfRoom: Bool
    let onFollowTap: () -> Void
    let onAnnouncementTap: () -> Void
    let onShareTap: () -> Void
    let onManagementTap: () -> Void
    let onMoreTap: () -> Void
    let onHeatTap: () -> Void
    let onViewerTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                anchorAvatarBlock
                anchorTextBlock
                // Component 11 关注按钮紧贴房间信息（房名/ID 右侧）；自己房间不显示（isSelfRoom）
                if !isSelfRoom {
                    followButton
                }
                Spacer(minLength: 8)
                toolbarIcons
            }
            statRow
        }
        .padding(.horizontal, Theme.Metric.partyRoomScreenH)
        .padding(.top, Theme.Metric.partyRoomTopBarV)
    }

    // MARK: - 头像

    /// 移除头像顶部装饰奖杯（原 partyTrophy 与设计稿 Component 定位冲突，误读为"左上角大榜单图标"）
    private var anchorAvatarBlock: some View {
        avatarCircle
            .frame(width: Theme.Metric.partyRoomAnchorAvatar,
                   height: Theme.Metric.partyRoomAnchorAvatar)
    }

    private var avatarCircle: some View {
        CachedAsyncImage(url: URL(string: anchorAvatarURL ?? ""),
                         contentMode: .fill,
                         cdn: (.avatarSmall, .fill)) {
            Circle().fill(Theme.Palette.partyRoomSeatFill)
                .overlay(
                    Image(systemName: "person.fill")
                        .foregroundColor(Theme.Palette.partyRoomSeatChair)
                )
        }
        .frame(width: Theme.Metric.partyRoomAnchorAvatar,
               height: Theme.Metric.partyRoomAnchorAvatar)
        .clipShape(Circle())
    }

    // MARK: - 主播名 + ID

    private var anchorTextBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(roomName)
                .font(Theme.Typography.partyRoomAnchorName)
                .foregroundColor(Theme.Palette.partyRoomAnchorName)
                .lineLimit(1)
                .truncationMode(.tail)
                // 88pt @16pt medium 约容 6-7 个西文字符或 4-5 个 CJK；超出走尾省略号。
                // 与 icon padding 2 组合让顶部行在 iPhone 13 mini(375pt) 内塞得下（诊断：溢出 47pt → 剩 1pt）
                .frame(maxWidth: 88, alignment: .leading)
            Text(idText)
                .font(Theme.Typography.partyRoomAnchorId)
                .foregroundColor(Theme.Palette.partyRoomAnchorId)
                .lineLimit(1)
        }
    }

    private var idText: String {
        String(format: L10n.PartyRoom.idFormat, roomId)
    }

    // MARK: - 关注按钮

    private var followButton: some View {
        Button(action: onFollowTap) {
            // v3：已关注 → `partyFollowCheck`（勾）；未关注 → `partyFollowUnchecked`（Component-follow 切图）
            // Fallback：Component-follow asset 未导入时未关注态用 partyFollowCheck 兜底，避免 Image 空渲染让按钮消失
            Image(followButtonAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: Theme.Metric.partyRoomFollowSize,
                       height: Theme.Metric.partyRoomFollowSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFollowing ? L10n.PartyRoom.a11yFollowing : L10n.PartyRoom.a11yFollow)
    }

    private var followButtonAssetName: String {
        if isFollowing { return "partyFollowCheck" }
        return UIImage(named: "partyFollowUnchecked") != nil ? "partyFollowUnchecked" : "partyFollowCheck"
    }

    // MARK: - 工具栏 4 个白线图标

    private var toolbarIcons: some View {
        HStack(spacing: Theme.Metric.partyRoomToolbarIconGap) {
            iconButton(asset: "partyIconAnnouncement",
                       label: L10n.PartyRoom.a11yAnnouncement,
                       action: onAnnouncementTap)
            iconButton(asset: "partyIconShare",
                       label: L10n.PartyRoom.a11yShare,
                       action: onShareTap)
            iconButton(asset: "partyIconManagement",
                       label: L10n.PartyRoom.a11yManagement,
                       action: onManagementTap)
            iconButton(asset: "partyIconMore",
                       label: L10n.PartyRoom.a11yMore,
                       action: onMoreTap)
        }
    }

    private func iconButton(asset: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(asset)
                .resizable()
                .renderingMode(.template)
                .foregroundColor(Theme.Palette.partyRoomToolbarIcon)
                .frame(width: Theme.Metric.partyRoomToolbarIconSize,
                       height: Theme.Metric.partyRoomToolbarIconSize)
                // padding 2（原 4）—— iPhone 13 mini 顶部行宽度合规化：4 图标各 26pt = 104 + 3 gap × 12 = 140
                .padding(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - 收益 / 观众数行

    private var statRow: some View {
        HStack(spacing: 4) {
            Button(action: onHeatTap) {
                HStack(spacing: 4) {
                    Image("partyTrophy")
                        .resizable().scaledToFit()
                        .frame(width: Theme.Metric.partyRoomStatIconSize,
                               height: Theme.Metric.partyRoomStatIconSize)
                    Text(heatText)
                        .font(Theme.Typography.partyRoomHeatNumber)
                        .foregroundColor(Theme.Palette.partyRoomHeatGold)
                    Image("partyArrowYellow")
                        .resizable().scaledToFit()
                        .frame(width: Theme.Metric.partyRoomStatArrowSize,
                               height: Theme.Metric.partyRoomStatArrowSize)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.PartyRoom.a11yHeat)

            Spacer()

            Button(action: onViewerTap) {
                HStack(spacing: 4) {
                    Image("partyIconViewer")
                        .resizable()
                        .renderingMode(.template)
                        .foregroundColor(Theme.Palette.partyRoomViewerCount)
                        .frame(width: Theme.Metric.partyRoomStatIconSize,
                               height: Theme.Metric.partyRoomStatIconSize)
                    Text(viewerCountText)
                        .font(Theme.Typography.partyRoomViewerNumber)
                        .foregroundColor(Theme.Palette.partyRoomViewerCount)
                    Image("partyArrowYellow")
                        .resizable().scaledToFit()
                        .frame(width: Theme.Metric.partyRoomStatArrowSize,
                               height: Theme.Metric.partyRoomStatArrowSize)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.PartyRoom.a11yViewers)
        }
        .padding(.vertical, Theme.Metric.partyRoomStatRowV)
    }
}
