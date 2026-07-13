import SwiftUI

/// 派对房大厅（E-spec §7 + §6B v3 设计稿还原）。
///
/// View 只读 `@ObservedObject var store: PartyListStore`（副作用全收敛进 Store，view 层零业务逻辑）。
/// 由 `PartyTabRootView` 挂载并持有 store；本 view 通过 3 个 callback 上抛导航意图。
///
/// **视觉范围**（v3 拍板 2026-07-10）：仅 Party 主 tab 视觉对齐设计稿——房间卡片新样式 +
/// 中心浮动 Create Room + crown badge（显图标业务不做）。**砍**顶部 3 pill / 搜索 / 语言 filter / Banner（推 F 期）。
struct PartyRoomListView: View {
    @ObservedObject var store: PartyListStore
    let onTapCreate: () -> Void
    let onTapCrown: () -> Void
    let onTapRoom: (String) -> Void

    /// E-spec §6B v4：keep-alive 架构下"用户是否真在看 party tab"信号（对齐 home 模式）。
    /// 首次变 true 时才拉数据，避免启动即预热。
    @Environment(\.isPartyTabActive) private var isPartyTabActive

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.Palette.partyListBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                contentArea
            }

            createRoomButton
                .padding(.bottom, 24)
        }
        .task(id: isPartyTabActive) {
            // keep-alive 下 .task 启动即触发，用 id: isPartyTabActive 让每次 tab 激活时重新计算 gate
            // 只在 isActive + idle 时拉；已 loaded 后切走再回来不重复拉（用户偏好保留状态）
            guard isPartyTabActive, case .idle = store.state else { return }
            store.startInitial()
        }
        .refreshable {
            // 必须 await 刷新完成，否则 sync 返回让 SwiftUI 立刻收 spinner
            // （见 rule list-refresh-preserve-items §"async closure 必须等到 task 完成"）
            await store.refreshAsync()
        }
        .navigationBarHidden(true)
        // iOS 16 已知：`.navigationBarHidden(true)` 会截断外层 `.safeAreaInset(edge: .bottom)` 的传播
        // （MainTabView 挂的 tabBarHostContainer 52pt inset 到不了这里）→ ScrollView 内容和
        // createRoomButton 会跨过 tabbar 顶延伸 → 底部被 tabbar 覆盖。此处补一层本地 safeAreaInset 兜底。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: Theme.Metric.tabBarHeight)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            Text(L10n.tabParty)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Theme.Palette.brandYellow, Theme.Palette.brandOrange, Theme.Palette.brandPinkA],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Spacer()

            crownBadge
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var crownBadge: some View {
        Button(action: onTapCrown) {
            HStack(spacing: 4) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.Palette.partyCrownGold)
                Text("+100K")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.Palette.partyCrownText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Theme.Palette.partyCrownBadgeBg)
            )
            .overlay(
                Capsule().stroke(Theme.Palette.partyCrownGold.opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Party ranking")
    }

    // MARK: - Content area (state-driven)

    @ViewBuilder
    private var contentArea: some View {
        switch store.state {
        case .idle, .loading:
            loadingView
        case .loaded(let rooms, let hasMore):
            if rooms.isEmpty {
                emptyView
            } else {
                roomList(rooms: rooms, hasMore: hasMore, showBottomLoader: false, pageErrorMessage: nil)
            }
        case .refreshing(let rooms):
            // list-refresh-preserve-items rule：下拉刷新期保留 rooms 视觉，顶部 spinner 由 .refreshable 自身管
            roomList(rooms: rooms, hasMore: false, showBottomLoader: false, pageErrorMessage: nil)
        case .loadingMore(let rooms):
            roomList(rooms: rooms, hasMore: true, showBottomLoader: true, pageErrorMessage: nil)
        case .error(let message, _):
            errorView(message: message)
        case .pageError(let rooms, let message):
            roomList(rooms: rooms, hasMore: true, showBottomLoader: false, pageErrorMessage: message)
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)
            Text(L10n.Party.loading)
                .font(.system(size: 13))
                .foregroundColor(Theme.Palette.partyGreeting)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        EmptyStateView(textColor: Theme.Palette.partyGreeting)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.Palette.partyGreeting)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                store.retry()
            } label: {
                Text(L10n.Party.listErrorRetry)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Room list

    private func roomList(rooms: [PartyRoomInfo], hasMore: Bool, showBottomLoader: Bool, pageErrorMessage: String?) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(rooms, id: \.stableListId) { room in
                    Button {
                        onTapRoom(room.id ?? "")
                    } label: {
                        PartyRoomCardView(room: room)
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if hasMore {
                    loadMoreSentinel(showLoader: showBottomLoader, pageErrorMessage: pageErrorMessage)
                }

                Color.clear.frame(height: 80)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .scrollIndicators(.hidden)
    }

    private func loadMoreSentinel(showLoader: Bool, pageErrorMessage: String?) -> some View {
        VStack(spacing: 6) {
            if let msg = pageErrorMessage {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                Button {
                    store.retryPage()
                } label: {
                    Text(L10n.Party.listErrorRetry)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
            } else if showLoader {
                ProgressView().tint(.white.opacity(0.6))
            } else {
                Text(L10n.Party.listLoadMore)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.partyGreeting)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .onAppear {
            if pageErrorMessage == nil && !showLoader {
                store.loadMore()
            }
        }
    }

    // MARK: - Create Room floating button

    private var createRoomButton: some View {
        Button(action: onTapCreate) {
            HStack(spacing: 6) {
                Image("partyCreatePlus")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(L10n.Party.listCreateRoom)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [Theme.Palette.partyCreateBtnA, Theme.Palette.partyCreateBtnB],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            )
            .shadow(color: Theme.Palette.partyCreateBtnA.opacity(0.5), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Party.listCreateRoom)
    }
}

// MARK: - Room card

/// 单个房间卡片（设计稿还原）：左圆形封面 + 右信息栏（房名/欢迎语/3 pill/观众头像堆叠）+ 右下热度。
struct PartyRoomCardView: View {
    let room: PartyRoomInfo

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            cover
            info
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.Palette.partyCardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.Palette.partyCardBorder, lineWidth: 0.5)
        )
    }

    private var cover: some View {
        Image("partyRoomCover")
            .resizable()
            .frame(width: 76, height: 76)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(room.roomName ?? L10n.Party.listUnnamed)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.Palette.partyRoomName)
                .lineLimit(1)

            Text(room.greetingMessage ?? L10n.Party.listWelcomeFallback)
                .font(.system(size: 12))
                .foregroundColor(Theme.Palette.partyGreeting)
                .lineLimit(1)

            HStack(spacing: 6) {
                pill(text: L10n.Party.listPillLiveVoice, gradient: [Theme.Palette.partyPillLiveA, Theme.Palette.partyPillLiveB])
                pill(text: L10n.Party.listPillVoice, gradient: [Theme.Palette.partyPillVoice, Theme.Palette.partyPillVoice])
                pill(text: room.roomLanguage ?? L10n.Party.listPillLanguageFallback, gradient: [Theme.Palette.partyPillLanguage, Theme.Palette.partyPillLanguage])
            }

            HStack(spacing: -6) {
                ForEach(previewAvatars(), id: \.self) { url in
                    avatarCircle(url: url)
                }
            }
            .frame(height: 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottomTrailing) {
            heatIndicator
        }
    }

    private func pill(text: String, gradient: [Color]) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Theme.Palette.partyPillText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(
                    LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing)
                )
            )
    }

    private func previewAvatars() -> [String] {
        let list = room.onlineUserList ?? []
        return list.prefix(4).compactMap { $0.avatar }.filter { !$0.isEmpty }
    }

    private func avatarCircle(url: String) -> some View {
        AvatarView(urlString: url, size: 20, kind: .user)
            .overlay(Circle().stroke(Theme.Palette.partyCardFill, lineWidth: 1.5))
    }

    private var heatIndicator: some View {
        HStack(spacing: 2) {
            Image("partyIconFire")
                .resizable()
                .frame(width: 12, height: 14)
                .accessibilityHidden(true)
            Text(heatText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.Palette.partyHeatText)
        }
    }

    /// 热度值：优先 heatValue（真实热度分），否则 fallback 到 onlineCount 预览人数
    private var heatText: String {
        if let h = room.heatValue, h > 0 {
            return "\(h)"
        }
        return "\(room.onlineCount)"
    }
}

// MARK: - Previews

#if DEBUG

/// 6 态 Preview 覆盖（E-spec §12 step 1b 要求）：loading / loaded / loadingMore / empty / error / pageError
struct PartyRoomListView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            preview(kind: .success(mockRooms(count: 4)), label: "loaded")
            preview(kind: .empty, label: "empty")
            preview(kind: .networkError, label: "error")
            preview(kind: .delayThenSuccess(mockRooms(count: 4), delayNanos: 999_000_000_000), label: "loading")
            preview(loadingMoreRooms: mockRooms(count: 4), label: "loadingMore")
            preview(pageErrorRooms: mockRooms(count: 4), pageErrorMessage: "network", label: "pageError")
        }
        .preferredColorScheme(.dark)
    }

    /// 通用：从 PreviewFake 起 state
    private static func preview(kind: PartyListServicePreviewFake.Kind, label: String) -> some View {
        let store = PartyListStore(service: PartyListServicePreviewFake(kind))
        store.startInitial()
        return PartyRoomListView(
            store: store,
            onTapCreate: {},
            onTapCrown: {},
            onTapRoom: { _ in }
        )
        .previewDisplayName(label)
    }

    /// loadingMore：直接构造已 loaded + 手动触发 loadMore 拉一个慢响应
    private static func preview(loadingMoreRooms rooms: [PartyRoomInfo], label: String) -> some View {
        let fake = PartyListServicePreviewFake(sequence: [
            .success(rooms),
            .delayThenSuccess(rooms, delayNanos: 999_000_000_000)
        ])
        let store = PartyListStore(service: fake)
        store.startInitial()
        // 用 Task 延迟触发 loadMore，Preview 内启动即可
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            store.loadMore()
        }
        return PartyRoomListView(
            store: store,
            onTapCreate: {},
            onTapCrown: {},
            onTapRoom: { _ in }
        )
        .previewDisplayName(label)
    }

    /// pageError：先 success，再触发 loadMore 拉 network error
    private static func preview(pageErrorRooms rooms: [PartyRoomInfo], pageErrorMessage: String, label: String) -> some View {
        let fake = PartyListServicePreviewFake(sequence: [
            .success(rooms),
            .networkError
        ])
        let store = PartyListStore(service: fake)
        store.startInitial()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            store.loadMore()
        }
        return PartyRoomListView(
            store: store,
            onTapCreate: {},
            onTapCrown: {},
            onTapRoom: { _ in }
        )
        .previewDisplayName(label)
    }

    static func mockRooms(count: Int) -> [PartyRoomInfo] {
        (0..<count).map { i in
            let json: [String: Any] = [
                "id": "room-\(i)",
                "roomName": ["Panda Steven 🔥🎖️", "Steven 🔥⭐r", "Steven 🔥🎖️r🇺🇳🎺", "Panda Steven 🇺🇳🎺"][i % 4],
                "greetingMessage": "Welcome to my room, let's have fun!",
                "lockFlag": i == 1 ? 1 : 0,
                "heatValue": [8, 88, 888, 8888][i % 4],
                "roomLanguage": "English",
                "onlineUserList": [
                    ["userId": "u1", "avatar": ""],
                    ["userId": "u2", "avatar": ""],
                    ["userId": "u3", "avatar": ""],
                    ["userId": "u4", "avatar": ""],
                    ["userId": "u5", "avatar": ""]
                ]
            ]
            let data = try! JSONSerialization.data(withJSONObject: json)
            return try! JSONDecoder().decode(PartyRoomInfo.self, from: data)
        }
    }
}

#endif
