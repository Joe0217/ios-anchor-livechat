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
    /// H5 仅在 audienceNum 非零时展示观众入口；iOS 由实时 chatroom 在线数派生。
    let showsViewerEntry: Bool
    /// 安卓主播端进房响应下发的右上角活动资源位；仅展示首条。
    let cornerBanner: PartyCornerBanner?
    let isFollowing: Bool
    /// v3：自己的房间（房主本人）不显示关注按钮（对齐 H5 用户端 index.vue 同 owner 隐藏 follow）
    let isSelfRoom: Bool
    /// 是否有管理权限（房主或房管）—— 决定房管按钮是否显示（对齐 H5 header-wrap.vue v-if=computedRoomRoleType!==NORMAL）
    let canManage: Bool
    /// v12：PK 入口是否可见（对齐 H5 `canStartPk`：canManage && roomTempId==1 && battleStore.isFunctionEnabled）
    /// iOS G 里程碑接 PK 前用 `canManage && roomTempIdInt == 1` 兜底（不判 feature flag）
    let canStartPk: Bool
    let onFollowTap: () -> Void
    /// H5 点击顶部房主头像打开用户名片。
    let onAnchorTap: () -> Void
    let onCornerBannerTap: (PartyCornerBanner) -> Void
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
    /// 主播周任务入口（安卓 WeekTaskDialog：上麦时长换奖励）。
    let showWeeklyTask: Bool
    let weeklyTaskRewardQuantity: Int
    let onWeeklyTaskTap: () -> Void
    /// 热门房任务由 `checkExistHot3` 确认后才展示，避免普通房误出现入口。
    let showHotTask: Bool
    let hotTaskStatus: PartyHotRoomTaskStatus?
    let hotTaskTopRankLimit: Int
    let onHotTaskTap: () -> Void
    /// 管理按钮 badge（对齐安卓 `tvMicApplicationNum`：queueSeatNum > 0 时房主主界面可见红角标）；
    /// 默认 0 不显示；房主/房管场景由 PartyRoomView 传 `store.queueSeatNum`
    var managementBadge: Int = 0

    /// v11：轮播索引（0=财富榜，1=荣耀榜）；5s 自动切换，对齐 H5 v-swiper autoplay=5000
    @State private var rankSwiperIndex: Int = 0
    /// 顶部统计栏须为观众人数保留右侧空间。
    private static let hotTaskEntryWidth: CGFloat = 92
    /// 顶部栏局部规格，避免影响其他 Party 页面。
    private static let statIconSize: CGFloat = 14
    private static let statArrowSize: CGFloat = 10
    private static let rankNumberFont = Font.system(size: 14, weight: .semibold)
    private static let viewerNumberFont = Font.system(size: 13, weight: .medium)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onAnchorTap) {
                    anchorAvatarBlock
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
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
        HStack(spacing: 4) {
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
                           badge: managementBadge,
                           action: onManagementTap)
            }
            iconButton(asset: "partyIconMore",
                       label: L10n.PartyRoom.a11yMore,
                       action: onMoreTap)
        }
    }

    private func iconButton(asset: String, label: String, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Image(asset)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundColor(Theme.Palette.partyRoomToolbarIcon)
                    .frame(width: Theme.Metric.partyRoomToolbarIconSize,
                           height: Theme.Metric.partyRoomToolbarIconSize)
                    // padding 2（原 4）—— iPhone 13 mini 顶部行宽度合规化：4 图标各 26pt = 104 + 3 gap × 4 = 116
                    .padding(2)
                // 对齐安卓 tvMicApplicationNum：badge > 0 显示右上角红角标
                if badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(Color.red))
                        .offset(x: 12, y: -12)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - 排名行（v11：对齐 H5 header-wrap.vue 第二行 h-24 · 财富/荣耀 5s 轮播 + 观众数）

    private var statRow: some View {
        fullStatRow
            .frame(maxWidth: .infinity, alignment: .leading)
            // 外层 VStack 已保留 6pt 行距；仅保留榜单行底部留白，避免顶部间距叠加为 12pt。
            .padding(.bottom, Theme.Metric.partyRoomStatRowV)
    }

    private var fullStatRow: some View {
        HStack(spacing: 4) {
            leadingStatContent
            Spacer(minLength: 8)
            trailingStatContent
        }
    }

    private var leadingStatContent: some View {
        HStack(spacing: 4) {
            rankSwiperButton
            taskEntries
        }
    }

    @ViewBuilder
    private var trailingStatContent: some View {
        HStack(spacing: 6) {
            if let banner = cornerBanner, banner.isDisplayable {
                cornerBannerButton(banner)
            }
            if showsViewerEntry {
                viewerButton
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var taskEntries: some View {
        if showWeeklyTask {
            weeklyTaskButton
        }
        if showHotTask {
            hotTaskEntry
        }
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
                    .frame(width: Self.statIconSize, height: Self.statIconSize)
                ZStack {
                    // 两个榜单数值共同决定宽度，轮播或其中一项刷新时均不会挤动右侧内容。
                    Text(wealthText)
                        .font(Self.rankNumberFont)
                        .lineLimit(1)
                        .hidden()
                    Text(honorText)
                        .font(Self.rankNumberFont)
                        .lineLimit(1)
                        .hidden()
                    Text(rankSwiperIndex == 0 ? wealthText : honorText)
                        .font(Self.rankNumberFont)
                        .foregroundColor(Theme.Palette.partyRoomHeatGold)
                        .lineLimit(1)
                        .id(rankSwiperIndex) // 触发 transition
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                .clipped()
                Image("partyArrowYellow")
                    .resizable().scaledToFit()
                    .frame(width: Self.statArrowSize, height: Self.statArrowSize)
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
                    .frame(width: Self.statIconSize, height: Self.statIconSize)
                Text(audienceCountText)
                    .font(Self.viewerNumberFont)
                    .foregroundColor(Theme.Palette.partyRoomViewerCount)
                Image("partyArrowYellow")
                    .resizable().scaledToFit()
                    .frame(width: Self.statArrowSize, height: Self.statArrowSize)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.PartyRoom.a11yViewers)
    }

    /// 固定 64×24 对齐安卓顶部活动位，避免异步图片改变统计栏布局。
    private func cornerBannerButton(_ banner: PartyCornerBanner) -> some View {
        Button { onCornerBannerTap(banner) } label: {
            CachedAsyncImage(url: URL(string: banner.picUrl ?? ""), contentMode: .fit, persistent: true) {
                Color.clear
            }
            .frame(width: 64, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var weeklyTaskButton: some View {
        Button(action: onWeeklyTaskTap) {
            HStack(spacing: 5) {
                Image("coins")
                    .resizable().scaledToFit()
                    .frame(width: 15, height: 15)
                Text("\(weeklyTaskRewardQuantity)")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(Color(hex: 0xFFFFD35C))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 22)
            .background(Color(hex: 0x4B2A7D).opacity(0.88), in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.PartyRoom.a11yWeeklyTask)
    }

    private var hotTaskButton: some View {
        Button(action: onHotTaskTap) {
            if let progress = hotTaskStatus?.topProgress, hotTaskStatus?.isActive == true {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(hex: 0x263B72).opacity(0.9))
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color(hex: 0xFF4DB7FF).opacity(0.82))
                            .frame(width: proxy.size.width * progress.fraction)
                    }
                    HStack(spacing: 0) {
                        Text(PartyRoomAnchorBar.durationText(progress.remaining))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .monospacedDigit()
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 0)
                        HStack(spacing: 0) {
                            Image("partyHotTaskChest")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 26, height: 25)
                            Text(progress.rewardText)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Color(hex: 0xFFFFD35C))
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(1)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(width: Self.hotTaskEntryWidth, height: 22)
                .clipShape(Capsule())
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 0) {
                    if hotTaskStatus != nil {
                        PartyHotTaskOutOfTopMarquee(text: hotTaskOutOfTopText)
                            .frame(width: Self.hotTaskOutOfTopTextWidth, height: 22)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: Self.hotTaskEntryWidth, height: 22, alignment: .leading)
                .background(Color(hex: 0x46526C).opacity(0.9), in: Capsule())
                .clipShape(Capsule())
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.PartyRoom.hotTaskTitle)
    }

    @ViewBuilder
    private var hotTaskEntry: some View {
        if hotTaskStatus?.isTopRoom == false {
            HStack(spacing: 0) {
                PartyHotTaskOutOfTopMarquee(text: hotTaskOutOfTopText)
                    .frame(width: Self.hotTaskOutOfTopTextWidth, height: 22)
            }
            .padding(.horizontal, 8)
            .frame(width: Self.hotTaskEntryWidth, height: 22, alignment: .leading)
            .background(Color(hex: 0x46526C).opacity(0.9), in: Capsule())
            .clipShape(Capsule())
            .accessibilityLabel(hotTaskOutOfTopText)
        } else {
            hotTaskButton
        }
    }

    private static func durationText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }

    /// 入口宽 92pt，扣除左右内边距后的跑马灯可视区域。
    private static let hotTaskOutOfTopTextWidth: CGFloat = hotTaskEntryWidth - 16

    private var hotTaskOutOfTopText: String {
        String(format: L10n.PartyRoom.hotTaskOutOfTopFormat, max(1, hotTaskTopRankLimit))
    }
}

private struct PartyHotTaskMarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 对齐 Android `tvOutOfTopTip` 的 MarqueeTextView：仅在文字超出可用宽度时从右向左循环滚动。
private struct PartyHotTaskOutOfTopMarquee: View {
    let text: String

    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private struct AnimationKey: Hashable {
        let text: String
        let availableWidth: Int
        let textWidth: Int
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Text(text)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.78))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .background {
                        GeometryReader { textProxy in
                            Color.clear.preference(
                                key: PartyHotTaskMarqueeTextWidthKey.self,
                                value: textProxy.size.width
                            )
                        }
                    }
                    .offset(x: offset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .mask(Rectangle())
            .onPreferenceChange(PartyHotTaskMarqueeTextWidthKey.self) { textWidth = $0 }
            .task(id: AnimationKey(
                text: text,
                availableWidth: Int((proxy.size.width * 100).rounded()),
                textWidth: Int((textWidth * 100).rounded())
            )) {
                let availableWidth = proxy.size.width
                guard textWidth > availableWidth, availableWidth > 0 else {
                    setOffsetWithoutAnimation(0)
                    return
                }

                let travel = availableWidth + textWidth
                let duration = max(1, Double(travel) / 35)
                let sleepNanoseconds = UInt64((duration * 1_000_000_000).rounded())

                setOffsetWithoutAnimation(availableWidth)
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch {
                    return
                }

                while !Task.isCancelled {
                    withAnimation(.linear(duration: duration)) {
                        offset = -textWidth
                    }
                    do {
                        try await Task.sleep(nanoseconds: sleepNanoseconds)
                    } catch {
                        return
                    }
                    setOffsetWithoutAnimation(availableWidth)
                }
            }
        }
    }

    private func setOffsetWithoutAnimation(_ value: CGFloat) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offset = value
        }
    }
}

/// v11：榜单类型（对齐 H5 `showRankPopupType` 分档：rank=财富榜 / honor=荣耀榜 / onlineUser=观众榜）
enum PartyRankKind {
    case wealth
    case honor
}
