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
    /// v12：房主头像装饰框 URL（对齐 H5 head-frame.vue，源自 `apiPartyGetUser.headFrameSmallImg`）
    /// SVGA / 静态图统一由 `HeadFrameView` 分流（v16 SVGA 已接 RemoteSVGAImageView 循环播放）
    let headFrameURL: String?
    /// v11 对齐 H5 header-wrap.vue：统计条从 heat+viewers 改为 wealth/honor 轮播 + audience
    let wealthText: String
    let honorText: String
    let audienceCountText: String
    let isFollowing: Bool
    /// v3：自己的房间（房主本人）不显示关注按钮（对齐 H5 用户端 index.vue 同 owner 隐藏 follow）
    let isSelfRoom: Bool
    /// 是否有管理权限（房主或房管）—— 决定房管按钮是否显示（对齐 H5 header-wrap.vue v-if=computedRoomRoleType!==NORMAL）
    let canManage: Bool
    /// v12：PK 入口是否可见（对齐 H5 `canStartPk`：canManage && roomTempId==1 && battleStore.isFunctionEnabled）
    /// iOS G 里程碑接 PK 前用 `canManage && roomTempIdInt == 1` 兜底（不判 feature flag）
    let canStartPk: Bool
    let onFollowTap: () -> Void
    /// v12：PK 入口点击（对齐 H5 `handleItemNoThrottleFn('startPk')`；iOS G 期接 PK 流程前暂 log/toast）
    let onPkTap: () -> Void
    let onAnnouncementTap: () -> Void
    let onShareTap: () -> Void
    let onManagementTap: () -> Void
    let onMoreTap: () -> Void
    /// v11：财富/荣耀榜入口（H5 里点击弹 RoomRank sheet 分别 type=rank/honor；iOS 待 F 期做榜单 sheet）
    let onRankTap: (PartyRankKind) -> Void
    /// v11：观众数入口（对齐 H5 userRank sheet；iOS 待 F 期）
    let onViewerTap: () -> Void

    /// v11：轮播索引（0=财富榜，1=荣耀榜）；5s 自动切换，对齐 H5 v-swiper autoplay=5000
    @State private var rankSwiperIndex: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                anchorAvatarBlock
                anchorTextBlock
                // Component 11 关注按钮紧贴房间信息（房名/ID 右侧）；自己房间不显示（isSelfRoom）
                if !isSelfRoom {
                    followButton
                }
                // v12：PK 入口（房主/房管 + roomTempId=1 + feature flag 时显示）
                if canStartPk {
                    pkButton
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

    /// v12：头像 + 装饰框（对齐 H5 header-wrap.vue L148-151：v-image 36×36 头像 + head-frame 45×45 装饰覆盖）
    /// iOS 主播端派对房头像 44pt；装饰框 55pt 略大覆盖形成"装饰环"视觉
    private var anchorAvatarBlock: some View {
        ZStack {
            avatarCircle
            headFrameDecoration
        }
        // 装饰框比头像大 → block 尺寸取装饰框；用 fixedSize 避免装饰框撑破外层 HStack
        .frame(width: Theme.Metric.partyRoomAnchorAvatar + 12,
               height: Theme.Metric.partyRoomAnchorAvatar + 12)
    }

    /// 头像装饰框（源自后端 `headFrameSmallImg`；对齐 H5 head-frame.vue 双路径 —— SVGA / 静态图）
    private var headFrameDecoration: some View {
        HeadFrameView(urlString: headFrameURL,
                      size: Theme.Metric.partyRoomAnchorAvatar + 12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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

    // MARK: - PK 入口（v12 对齐 H5 header-wrap.vue L167 `pk-room-top-icon.webp`）

    private var pkButton: some View {
        Button(action: onPkTap) {
            // 切图未提供，fallback 到 iOS 现有 `livePkIcon`（直播 PK icon）视觉近似；等 pk-room-top-icon asset 补齐后自动切换
            Image(UIImage(named: "partyPkTopIcon") != nil ? "partyPkTopIcon" : "livePkIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.PartyRoom.a11yPk)
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
            // 管理按钮：仅房主/房管显示（对齐 H5 header-wrap.vue v-if=computedRoomRoleType!==NORMAL）
            if canManage {
                iconButton(asset: "partyIconManagement",
                           label: L10n.PartyRoom.a11yManagement,
                           action: onManagementTap)
            }
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

    // MARK: - 排名行（v11：对齐 H5 header-wrap.vue 第二行 h-24 · 财富/荣耀 5s 轮播 + 观众数）

    private var statRow: some View {
        HStack(spacing: 4) {
            rankSwiperButton
            Spacer()
            viewerButton
        }
        .padding(.vertical, Theme.Metric.partyRoomStatRowV)
    }

    /// 左侧：icon_rank + 数值轮播（contribution ↔ honor 5s 自切）+ 右黄箭头
    /// 点击 → onRankTap(当前展示的榜单类型)
    private var rankSwiperButton: some View {
        Button {
            let kind: PartyRankKind = (rankSwiperIndex == 0) ? .wealth : .honor
            onRankTap(kind)
        } label: {
            HStack(spacing: 4) {
                Image("partyTrophy")
                    .resizable().scaledToFit()
                    .frame(width: Theme.Metric.partyRoomStatIconSize,
                           height: Theme.Metric.partyRoomStatIconSize)
                // 数值区固定宽度避免轮播时布局跳动
                ZStack {
                    Text(rankSwiperIndex == 0 ? wealthText : honorText)
                        .font(Theme.Typography.partyRoomHeatNumber)
                        .foregroundColor(Theme.Palette.partyRoomHeatGold)
                        .lineLimit(1)
                        .id(rankSwiperIndex) // 触发 transition
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                .frame(minWidth: 40, alignment: .leading)
                .clipped()
                Image("partyArrowYellow")
                    .resizable().scaledToFit()
                    .frame(width: Theme.Metric.partyRoomStatArrowSize,
                           height: Theme.Metric.partyRoomStatArrowSize)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rankSwiperIndex == 0 ? L10n.PartyRoom.a11yWealthRank : L10n.PartyRoom.a11yHonorRank)
        .task {
            // 5s 循环切换（对齐 H5 v-swiper autoplay=5000）；view dismount 时 task 自动 cancel
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    rankSwiperIndex = (rankSwiperIndex + 1) % 2
                }
            }
        }
    }

    /// 右侧：观众 icon + audienceCountText + 右灰箭头
    private var viewerButton: some View {
        Button(action: onViewerTap) {
            HStack(spacing: 4) {
                Image("partyIconViewer")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundColor(Theme.Palette.partyRoomViewerCount)
                    .frame(width: Theme.Metric.partyRoomStatIconSize,
                           height: Theme.Metric.partyRoomStatIconSize)
                Text(audienceCountText)
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
}

/// v11：榜单类型（对齐 H5 `showRankPopupType` 分档：rank=财富榜 / honor=荣耀榜 / onlineUser=观众榜）
enum PartyRankKind {
    case wealth
    case honor
}
