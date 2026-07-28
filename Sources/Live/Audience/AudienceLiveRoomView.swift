import SwiftUI

/// 其他主播的直播房，对齐 H5 `views/liveRoom/index.vue`。
///
/// 该页面只消费远端 RTC 画面，保留客态可见的直播间数据和公屏，不挂主播侧相机、心跳、
/// 美颜、开播设置或下播动作。用户退出页面时只离开 Agora/云信房间。
struct AudienceLiveRoomView: View {
    let anchor: LiveStreamAnchor

    @StateObject private var store: AudienceLiveRoomStore
    @StateObject private var agora = AgoraManager()
    @StateObject private var nim = NIMChatroomManager()
    @StateObject private var publicChatFeed = UnifiedPublicChatFeed(limit: 200)
    @StateObject private var audiencePKStore = AudiencePKStore()

    @State private var didConnect = false
    @State private var joinedOpponentChannel = ""
    @State private var showContribution = false
    @State private var showAnchorRank = false
    @State private var showAudienceRank = false
    /// H5 顶部 Top2 与观众数共用用户周榜，但分别落在送礼榜和观众列表首 Tab。
    @State private var audienceRankInitialTopTab: RankSheetTopTab = .viewers
    @State private var showTask = false
    @State private var showWishlist = false
    @State private var userCardUserId: String?
    @State private var chatSheetPeerYxAccId: String?
    @State private var pkRankSide: PKRankSide?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openUserProfile) private var openUserProfile

    init(anchor: LiveStreamAnchor,
         service: AudienceLiveRoomServiceProtocol = AudienceLiveRoomService()) {
        self.anchor = anchor
        _store = StateObject(wrappedValue: AudienceLiveRoomStore(service: service))
    }

    var body: some View {
        roomContent
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .task { await store.join(anchor: anchor) }
            .onChange(of: store.state, perform: handleRoomStateChange)
            .onChange(of: agora.state, perform: handleAgoraStateChange)
            .onChange(of: audiencePKStore.phase, perform: handlePKPhaseChange)
            .onChange(of: audiencePKStore.isOpponentMuted) { muted in
                guard let opponentId = audiencePKStore.opponentUserId,
                      !joinedOpponentChannel.isEmpty else { return }
                agora.mutePKOppositeAudio(
                    channel: joinedOpponentChannel,
                    uid: UInt(opponentId),
                    muted: muted
                )
            }
            .onDisappear(perform: handleDisappear)
            .onReceive(nim.messagesStore.$messages) { messages in
                publicChatFeed.replace(messages.map(LivePublicChatAdapter.adapt))
            }
            .modifier(LiveOverlayHost(
                giftQueue: nim.giftAnimationQueue,
                enterRoomQueue: nim.enterRoomQueue,
                diamondQueue: nim.diamondGiftQueue,
                wishAchievedQueue: nim.wishAchievedQueue
            ))
            .userCardSheet(
                item: Binding(
                    get: { userCardUserId.map { UserCardPresentation(userId: $0) } },
                    set: { userCardUserId = $0?.userId }
                ),
                onAvatarTap: openUserProfileFromCard,
                onMessageTap: { _, yxAccid in
                    guard let yxAccid, !yxAccid.isEmpty else { return }
                    // 与主播端 H5 的 openTalkPopup 一致：关闭名片卡后展示半屏私聊。
                    userCardUserId = nil
                    DispatchQueue.main.async {
                        chatSheetPeerYxAccId = yxAccid
                    }
                }
            )
            .avatarUserCardPresenter { userCardUserId = $0 }
            .avatarTapEnvironmentOverride(.liveRoom)
            .sheet(isPresented: $showContribution) { contributionSheet }
            .sheet(isPresented: $showAnchorRank) { anchorRankSheet }
            .sheet(isPresented: $showAudienceRank) { audienceRankSheet }
            .sheet(isPresented: $showTask) { taskSheet }
            .sheet(isPresented: $showWishlist) { wishlistSheet }
            .sheet(item: $pkRankSide) { side in pkRankSheet(side: side) }
            .giftEffectScene(.live, scopeId: sceneScopeId)
            .enterEffectScene(.live, scopeId: sceneScopeId)
            .chatDetailBottomSheet(peer: $chatSheetPeerYxAccId,
                                   selfYxAccId: SessionStore.shared.user?.yxAccid ?? "")
    }

    @ViewBuilder
    private var roomContent: some View {
        ZStack {
            Theme.Palette.liveBottomDark.ignoresSafeArea()
            remoteVideoLayer

            switch store.state {
            case .live(let info):
                liveOverlay(info)
            case .idle, .joining:
                ProgressView().tint(.white)
            case .calling:
                statusOverlay(icon: "phone.fill", message: L10n.callSubtitleCallingOut, allowsRetry: false)
            case .ended:
                statusOverlay(icon: "video.slash.fill", message: L10n.liveRoomStatusIdle, allowsRetry: false)
            case .failed(let message):
                statusOverlay(icon: "exclamationmark.triangle.fill", message: message, allowsRetry: true)
            }
        }
    }

    @ViewBuilder
    private var remoteVideoLayer: some View {
        if case .live = store.state {
            if audiencePKStore.isShowing {
                HStack(spacing: 0) {
                    RemoteVideoView(manager: agora)
                    PKOppositeContainer(view: agora.oppositeRemoteView)
                }
                .ignoresSafeArea()
                .background(Theme.Palette.liveBottomDark)
            } else {
                RemoteVideoView(manager: agora)
                    .ignoresSafeArea()
                    .background(Theme.Palette.liveBottomDark)
            }
        } else {
            CachedAsyncImage(
                url: anchor.backgroundImgURL,
                contentMode: .fill,
                persistent: true,
                cdn: (.custom(width: 800), .fill)
            ) {
                Theme.Palette.liveBottomDark
            }
            .ignoresSafeArea()
            .overlay(Color.black.opacity(0.45).ignoresSafeArea())
        }
    }

    private func liveOverlay(_ info: AudienceLiveRoomInfo) -> some View {
        VStack(spacing: 0) {
            AudienceLiveRoomHeader(
                info: info,
                presence: nim.presenceStore,
                topRankStore: nim.topRankStore,
                onAnchorTap: { userCardUserId = info.anchorUserIdString },
                onTopGifterTap: { _ in
                    audienceRankInitialTopTab = .topGifter
                    showAudienceRank = true
                },
                onAudienceTap: {
                    audienceRankInitialTopTab = .viewers
                    showAudienceRank = true
                },
                onClose: leaveRoom
            )
            .padding(.horizontal, Theme.Metric.liveRoomScreenHPadding)
            .padding(.top, 8)

            AudienceLiveRoomBadges(
                contributionStore: nim.contributionStore,
                anchorRankStore: nim.anchorRankStore,
                taskStore: nim.liveGiftTaskStore,
                onTaskTap: { showTask = true },
                onContributionTap: { showContribution = true },
                onRankTap: { showAnchorRank = true }
            )
            .padding(.horizontal, Theme.Metric.liveRoomScreenHPadding)
            .padding(.top, 10)

            if !nim.wishlistStore.items.isEmpty {
                AudienceWishlistCard(store: nim.wishlistStore, onTap: { showWishlist = true })
                    .padding(.horizontal, Theme.Metric.liveRoomScreenHPadding)
                    .padding(.top, 8)
            }

            if audiencePKStore.isShowing {
                AudiencePKOverlay(store: audiencePKStore,
                                  onOpponentTap: { userCardUserId = String($0) },
                                  onRankTap: { pkRankSide = $0 })
                    .padding(.horizontal, Theme.Metric.liveRoomScreenHPadding)
                    .padding(.top, 12)
            }

            Spacer(minLength: 0)

            HStack(alignment: .bottom, spacing: 10) {
                VStack(spacing: 0) {
                    PaidBulletFloat(queue: nim.paidBulletQueue)
                    PublicChatListView(feed: publicChatFeed, theme: .live)
                        .frame(maxHeight: 260)
                }
                Spacer(minLength: 0)
                QuickGoLiveButton()
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, Theme.Metric.liveRoomScreenHPadding)
            .padding(.bottom, 12)
        }
    }

    private func statusOverlay(icon: String, message: String, allowsRetry: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            if allowsRetry {
                Button(L10n.liveRoomRetry) {
                    Task { await store.retry(anchor: anchor) }
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            Button(action: leaveRoom) {
                Image("liveRoomCloseButton")
                    .resizable()
                    .frame(width: Theme.Metric.liveRoomCloseSize,
                           height: Theme.Metric.liveRoomCloseSize)
            }
            .accessibilityLabel(Text(L10n.liveRoomCloseA11y))
        }
        .padding(24)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var contributionSheet: some View {
        Group {
            if let info = currentRoomInfo {
                ContributionSheetView(
                    anchorId: info.anchorUserIdString,
                    roomId: String(info.liveRecordId),
                    currentIncome: nim.contributionStore.currentLiveIncome,
                    isPresented: $showContribution,
                    onUserTap: { userCardUserId = $0 }
                )
                .sheetTopInset()
                .presentationDetents([.fraction(0.4)])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var anchorRankSheet: some View {
        Group {
            if let info = currentRoomInfo {
                RankSheetView(
                    anchorUserId: info.anchorUserIdString,
                    isPresented: $showAnchorRank,
                    onRankUpdate: { nim.anchorRankStore.setRank($0) },
                    onUserTap: { userCardUserId = $0 }
                )
                .presentationDetents([.fraction(0.4)])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var audienceRankSheet: some View {
        Group {
            if let info = currentRoomInfo {
                UserWeeklyRankSheetView(
                    isPresented: $showAudienceRank,
                    anchorUserId: info.anchorUserId,
                    dbId: info.liveRecordId,
                    initialTopTab: audienceRankInitialTopTab,
                    onUserTap: { userCardUserId = $0 }
                )
                .sheetTopInset()
                .presentationDetents([.fraction(0.4)])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var taskSheet: some View {
        Group {
            if let info = currentRoomInfo {
                LiveGiftTaskSheet(
                    store: nim.liveGiftTaskStore,
                    anchorId: info.anchorUserIdString,
                    isPresented: $showTask,
                    onUserTap: { userCardUserId = $0 }
                )
                .sheetTopInset()
                .presentationDetents([.fraction(0.4)])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var wishlistSheet: some View {
        Group {
            if let info = currentRoomInfo {
                WishlistAnchorPanel(
                    store: nim.wishlistStore,
                    isPresented: $showWishlist,
                    liveRecordId: String(info.liveRecordId),
                    onGifterTap: { userCardUserId = $0 }
                )
                .sheetTopInset()
                .giftPanelSheetBackground()
                .presentationDetents([.fraction(0.4)])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var currentRoomInfo: AudienceLiveRoomInfo? {
        if case .live(let info) = store.state { return info }
        return nil
    }

    private var sceneScopeId: String {
        currentRoomInfo.map { String($0.yxRoomId) } ?? ""
    }

    @ViewBuilder
    private func pkRankSheet(side: PKRankSide) -> some View {
        if let left = audiencePKStore.left,
           let right = audiencePKStore.right,
           !audiencePKStore.pkId.isEmpty {
            let selectedAnchor = side == .my ? left : right
            PKRankSheetView(side: side,
                            pkId: audiencePKStore.pkId,
                            anchorId: selectedAnchor.userId,
                            anchorAvatarURL: selectedAnchor.avatarURL,
                            anchorNickname: selectedAnchor.nickname)
                .presentationDetents([.fraction(0.5)])
                .presentationDragIndicator(.visible)
        }
    }

    private func handleRoomStateChange(_ state: AudienceLiveRoomState) {
        switch state {
        case .live(let info):
            connect(to: info)
        case .ended:
            leaveRoom()
        case .idle, .joining, .calling, .failed:
            break
        }
    }

    private func handleAgoraStateChange(_ state: AgoraManager.State) {
        guard state == .failed, didConnect else { return }
        let message = agora.message.isEmpty ? L10n.liveRoomStatusFailed : agora.message
        didConnect = false
        nim.leave()
        NIMService.shared.unregisterRouter(audiencePKStore.router)
        leaveOpponentPKChannel()
        audiencePKStore.reset()
        Task {
            await agora.leave()
            store.markFailed(message)
        }
    }

    private func connect(to info: AudienceLiveRoomInfo) {
        guard !didConnect else { return }
        didConnect = true

        let currentUser = SessionStore.shared.user
        let audienceStore = store
        nim.onRoomEnded = { [weak audienceStore] in
            Task { @MainActor in audienceStore?.markEnded() }
        }
        nim.configureAudience(ownerYxAccount: info.anchorYxAccid)
        nim.configurePaidBullet(
            roomId: info.liveRecordId,
            viewerUserId: currentUser?.userId ?? 0,
            countryCode: info.anchorCountryCode
                ?? AnchorInfoStore.shared.info?.countryCode
                ?? AnchorInfoStore.shared.mine?.countryCode
                ?? ""
        )
        nim.contributionStore.configure(anchorUserId: info.anchorUserIdString)
        nim.anchorRankStore.configure(anchorUserId: info.anchorUserIdString)
        nim.topRankStore.setRoomId(info.liveRecordId)
        nim.contributionStore.loadInitial()
        nim.anchorRankStore.loadInitial()
        nim.topRankStore.loadInitial()
        nim.wishlistStore.loadInitial(
            anchorUserId: info.anchorUserIdString,
            anchorNickname: info.anchorNickname
        )
        nim.liveGiftTaskStore.loadInitial(anchorUserId: info.anchorUserIdString)
        nim.enter(
            roomId: String(info.yxRoomId),
            nickname: currentUser?.nickname ?? L10n.liveRoomAnchorDefault
        )
        agora.join(
            channelId: info.agoraChannelId,
            token: info.rtcToken,
            uid: UInt(currentUser?.userId ?? 0),
            role: .audience
        )
        NIMService.shared.registerRouter(audiencePKStore.router)
        audiencePKStore.loadIfNeeded(room: info)
    }

    private func handlePKPhaseChange(_ phase: AudiencePKStore.Phase) {
        if audiencePKStore.isShowing {
            joinOpponentPKChannelIfNeeded()
        } else if phase == .idle {
            leaveOpponentPKChannel()
        }
    }

    private func joinOpponentPKChannelIfNeeded() {
        guard let info = currentRoomInfo,
              let channel = audiencePKStore.opponentChannelId,
              let opponentId = audiencePKStore.opponentUserId,
              channel != joinedOpponentChannel else { return }
        let ownUid = UInt(SessionStore.shared.user?.userId ?? 0)
        guard ownUid > 0 else { return }
        joinedOpponentChannel = channel
        Task {
            do {
                try await agora.joinPKOpposite(
                    channel: channel,
                    oppositeUid: UInt(opponentId),
                    token: info.rtcToken,
                    ownUid: ownUid
                )
                if audiencePKStore.isOpponentMuted {
                    agora.mutePKOppositeAudio(channel: channel, uid: UInt(opponentId), muted: true)
                }
            } catch {
                // 主直播不中断；对手频道订阅失败时退化为单主播画面，等待下一条状态消息重试。
                joinedOpponentChannel = ""
            }
        }
    }

    private func leaveOpponentPKChannel() {
        let channel = joinedOpponentChannel
        joinedOpponentChannel = ""
        guard !channel.isEmpty else { return }
        Task { await agora.leavePKOpposite(channel: channel) }
    }

    private func handleDisappear() {
        // SwiftUI 在进入后台时会发 onDisappear；客态也保留远端订阅，回前台无需重新入房。
        guard scenePhase != .background else { return }
        leaveRoomResources()
    }

    private func leaveRoom() {
        leaveRoomResources()
        dismiss()
    }

    /// H5 客态名片跳详情走 `leaveLiveRoom → router.replace('/userProfile')`；
    /// iOS 先 pop 客态房，再由 Home 的路由总线 push 详情，避免返回到已断开的 RTC 页面。
    private func openUserProfileFromCard() {
        guard let userId = userCardUserId, !userId.isEmpty else { return }
        userCardUserId = nil
        leaveRoomResources()
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            openUserProfile.perform(userId)
        }
    }

    private func leaveRoomResources() {
        guard didConnect else {
            store.cancel()
            return
        }
        didConnect = false
        store.cancel()
        nim.leave()
        NIMService.shared.unregisterRouter(audiencePKStore.router)
        leaveOpponentPKChannel()
        audiencePKStore.reset()
        nim.contributionStore.clear()
        nim.anchorRankStore.configure(anchorUserId: "")
        nim.topRankStore.clear()
        nim.wishlistStore.reset()
        nim.liveGiftTaskStore.reset()
        Task { await agora.leave() }
    }
}

private struct AudienceLiveRoomHeader: View {
    let info: AudienceLiveRoomInfo
    @ObservedObject var presence: ChatPresenceStore
    @ObservedObject var topRankStore: LiveTopRankStore
    let onAnchorTap: () -> Void
    let onTopGifterTap: (String) -> Void
    let onAudienceTap: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onAnchorTap) {
                HStack(spacing: 6) {
                    AvatarView(
                        urlString: info.anchorAvatarURL,
                        size: Theme.Metric.liveRoomChipAvatar,
                        kind: .anchor,
                        userId: info.anchorUserIdString,
                        disablesTap: true
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(info.anchorNickname)
                            .font(Theme.Typography.liveRoomAnchorName)
                            .foregroundStyle(Theme.Palette.liveRoomAnchorName)
                            .lineLimit(1)
                        HStack(spacing: 3) {
                            Image("liveRoomHotIcon")
                                .resizable()
                                .frame(width: 10, height: 10)
                            Text(info.hotScore, format: .number)
                                .font(Theme.Typography.liveRoomAnchorMeta)
                                .foregroundStyle(Theme.Palette.liveRoomAnchorMeta)
                        }
                    }
                }
                .padding(.horizontal, Theme.Metric.liveRoomChipHPadding)
                .padding(.vertical, Theme.Metric.liveRoomChipVPadding)
                .background(Theme.Palette.liveRoomChipBackground, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(info.anchorNickname))

            Spacer(minLength: 0)
            topGifters
            Button(action: onAudienceTap) {
                ZStack(alignment: .topTrailing) {
                    Image("liveRoomViewerCountIcon")
                        .resizable()
                        .frame(width: Theme.Metric.liveRoomViewerCountSize,
                               height: Theme.Metric.liveRoomViewerCountSize)
                    if presence.onlineCount > 0 {
                        Text(onlineCountText)
                            .font(Theme.Typography.liveRoomViewerCount)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.black.opacity(0.6), in: Capsule())
                            .offset(x: 4, y: -4)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.liveRoomViewerCountA11y))
            Button(action: onClose) {
                Image("liveRoomCloseButton")
                    .resizable()
                    .frame(width: Theme.Metric.liveRoomCloseSize,
                           height: Theme.Metric.liveRoomCloseSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.liveRoomCloseA11y))
        }
    }

    @ViewBuilder
    private var topGifters: some View {
        if let first = topRankStore.items.first, first.cost > 1 {
            HStack(spacing: -6) {
                ForEach(topRankStore.items) { item in
                    Button { onTopGifterTap(item.userId) } label: {
                        AvatarView(
                            urlString: item.avatarUrl,
                            size: Theme.Metric.liveRoomTopViewerSize,
                            kind: .user,
                            userId: item.userId,
                            disablesTap: true
                        )
                        .overlay(Circle().stroke(item.rank == 1 ? Color(hex: 0xFFC33A) : Color(hex: 0xC2CCEC), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var onlineCountText: String {
        presence.onlineCount < 1000 ? "\(presence.onlineCount)" : "\(presence.onlineCount / 1000)k+"
    }
}

private struct AudienceLiveRoomBadges: View {
    @ObservedObject var contributionStore: LiveContributionStore
    @ObservedObject var anchorRankStore: LiveAnchorRankStore
    @ObservedObject var taskStore: LiveGiftTaskStore
    let onTaskTap: () -> Void
    let onContributionTap: () -> Void
    let onRankTap: () -> Void

    var body: some View {
        HStack(spacing: Theme.Metric.liveRoomBadgeGap) {
            if taskStore.isIconVisible {
                Button(action: onTaskTap) {
                    Image("liveRoomTaskBadge")
                        .resizable()
                        .frame(width: Theme.Metric.liveRoomBadgeHeight,
                               height: Theme.Metric.liveRoomBadgeHeight)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.liveRoomTaskA11y))
            }
            Button(action: onContributionTap) {
                HStack(spacing: 4) {
                    Image("coins")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                    Text("\(contributionStore.currentLiveIncome)")
                        .font(Theme.Typography.liveRoomBadgeText)
                        .foregroundStyle(Theme.Palette.liveRoomBadgeNumber)
                }
                .padding(.horizontal, 8)
                .frame(height: Theme.Metric.liveRoomBadgeHeight)
                .background(Theme.Palette.liveRoomBadgeBackground,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.liveRoomBadge))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.liveRoomContributionA11y))
            Button(action: onRankTap) {
                HStack(spacing: 4) {
                    Image("liveRoomRankIcon")
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(anchorRankStore.displayText)
                        .font(Theme.Typography.liveRoomBadgeText)
                        .foregroundStyle(Theme.Palette.liveRoomBadgeNumber)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.Palette.liveRoomBadgeNumber)
                }
                .padding(.horizontal, 8)
                .frame(height: Theme.Metric.liveRoomBadgeHeight)
                .background(Theme.Palette.liveRoomBadgeBackground,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.liveRoomBadge))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.liveRoomRankA11y))
            Spacer(minLength: 0)
        }
    }
}

private struct AudienceWishlistCard: View {
    @ObservedObject var store: WishlistStore
    let onTap: () -> Void

    var body: some View {
        if let item = store.items.first {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    CachedAsyncImage(
                        url: item.giftIconUrl.flatMap(URL.init(string:)),
                        contentMode: .fit,
                        cdn: (.gift, .fit)
                    ) {
                        Image(systemName: "gift.fill")
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.giftName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.2))
                                Capsule()
                                    .fill(Color(hex: 0xFE00DE))
                                    .frame(width: proxy.size.width * item.progress)
                            }
                        }
                        .frame(height: 4)
                        Text("\(item.completedCount) / \(item.targetCount)")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .padding(8)
                .frame(width: 150, alignment: .leading)
                .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }
}
