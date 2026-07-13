import SwiftUI

/// 派对房列表内容区（E 增强 refactor：Party/Follow/Recent 3 tab 复用）。
///
/// **重构历史**（2026-07-10）：原 PartyRoomListView 含 header/crownBadge/createRoomButton 混在一起。
/// E 增强将顶部 3 tab / 语言 pill / 榜单卡 / 浮动按钮上移到 `PartyListMainView`，本文件降级为
/// 纯"内容区"组件，泛型 `Store: PartyRoomListLike` 让 3 个 tab 共用同一份 UI 实现。
///
/// **spec §7 §12 F 期演进笔记**已在 v3 落地；E 增强对齐 H5 用户端 `/party/index.vue` 3-tab TabView(.page)。
struct PartyRoomListContent<Store: PartyRoomListLike>: View {
    @ObservedObject var store: Store
    let onTapRoom: (String) -> Void
    /// Follow/Recent tab 需要在 `.loaded(rooms: [])` 时显 "Coming soon" 空态；Party tab 显常规空态。
    let comingSoonOnEmpty: Bool

    var body: some View {
        contentArea
    }

    // MARK: - Content area (state-driven)

    @ViewBuilder
    private var contentArea: some View {
        switch store.state {
        case .idle, .loading:
            // Follow/Recent 未接入真接口前，store 停在 .idle，view 直接显 Coming soon 空态而非 spinner
            if comingSoonOnEmpty { comingSoonView } else { loadingView }
        case .loaded(let rooms, let hasMore):
            if rooms.isEmpty {
                if comingSoonOnEmpty { comingSoonView } else { emptyView }
            } else {
                roomList(rooms: rooms, hasMore: hasMore, showBottomLoader: false, pageErrorMessage: nil)
            }
        case .refreshing(let rooms):
            // list-refresh-preserve-items rule：下拉刷新期保留 rooms 视觉，顶部 spinner 由 .refreshable 自身管
            // hasMore 传 true 保持底部 loadMoreSentinel 显示；避免 loaded→refreshing→loaded 时 sentinel 闪烁
            // （loadMore() 内部对 .refreshing 态是 no-op，sentinel onAppear 触发不会重入）
            roomList(rooms: rooms, hasMore: true, showBottomLoader: false, pageErrorMessage: nil)
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
            ProgressView().tint(.white)
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

    /// Follow/Recent tab 未接入真接口前的空态（E 增强）。
    private var comingSoonView: some View {
        VStack(spacing: 14) {
            Image(systemName: "hourglass")
                .font(.system(size: 42))
                .foregroundColor(Theme.Palette.partyGreeting)
            Text(L10n.Party.comingSoon)
                .font(.system(size: 14))
                .foregroundColor(Theme.Palette.partyGreeting)
        }
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

/// PartyRoomListContent 精简 preview（E 增强 refactor 后）：3 态覆盖，Party 全量 preview 移到 PartyListMainView。
struct PartyRoomListContent_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            content(kind: .success(mockRooms(count: 4)), label: "loaded")
            content(kind: .empty, label: "empty")
            content(kind: .networkError, label: "error")
        }
        .preferredColorScheme(.dark)
    }

    private static func content(kind: PartyListServicePreviewFake.Kind, label: String) -> some View {
        let store = PartyListStore(service: PartyListServicePreviewFake(kind))
        store.startInitial()
        return PartyRoomListContent(store: store, onTapRoom: { _ in }, comingSoonOnEmpty: false)
            .previewDisplayName(label)
            .background(Theme.Palette.partyListBackground)
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
                    ["userId": "u2", "avatar": ""]
                ]
            ]
            let data = try! JSONSerialization.data(withJSONObject: json)
            return try! JSONDecoder().decode(PartyRoomInfo.self, from: data)
        }
    }
}

#endif
