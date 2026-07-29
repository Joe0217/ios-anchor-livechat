import SwiftUI

private struct PartyRoomMarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 对齐 H5 `van-notice-bar`：文字溢出时以 35pt/s 从右向左循环滚动。
/// 语言 pill 不使用本组件，保持 H5 的静态展示。
private struct PartyRoomRightToLeftMarquee: View {
    let text: String
    let font: Font
    let foregroundColor: Color

    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private struct Key: Hashable {
        let text: String
        let availableWidth: Int
        let textWidth: Int
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Text(text)
                    .font(font)
                    .foregroundColor(foregroundColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .background {
                        GeometryReader { textProxy in
                            Color.clear.preference(
                                key: PartyRoomMarqueeTextWidthKey.self,
                                value: textProxy.size.width
                            )
                        }
                    }
                    .offset(x: offset)
            }
            .clipped()
            .onPreferenceChange(PartyRoomMarqueeTextWidthKey.self) { textWidth = $0 }
            .task(id: Key(
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

/// 派对房列表内容区（E 增强 refactor：Party/Follow/Recent 3 tab 复用）。
///
/// **重构历史**（2026-07-10）：原 PartyRoomListView 含 header/crownBadge/createRoomButton 混在一起。
/// E 增强将顶部 3 tab / 语言 pill / 榜单卡 / 浮动按钮上移到 `PartyListMainView`，本文件降级为
/// 纯"内容区"组件，泛型 `Store: PartyRoomListLike` 让 3 个 tab 共用同一份 UI 实现。
///
/// **spec §7 §12 F 期演进笔记**已在 v3 落地；E 增强对齐 H5 用户端 `/party/index.vue` 3-tab TabView(.page)。
struct PartyRoomListContent<Store: PartyRoomListLike>: View {
    @ObservedObject var store: Store
    /// H5 的房间语言展示通过全局 Party language list 将 code 转成名称。
    /// Follow/Recent 也复用 Party 首页已加载的同一份列表。
    let languages: [PartyLanguage]
    /// H5 以当前用户房间判断列表项是否为 My Room。
    let myRoomID: String?
    /// v4：传完整对象让上层判密码房/其他前置逻辑
    let onTapRoom: (PartyRoomInfo) -> Void
    /// 保留给调用方的空态策略；H5 三个 tab 均使用同一种 Party 空态。
    let comingSoonOnEmpty: Bool

    var body: some View {
        contentArea
    }

    // MARK: - Content area (state-driven)

    @ViewBuilder
    private var contentArea: some View {
        switch store.state {
        case .idle, .loading:
            // v7：非滚动态用 scrollWrap 包一层 ScrollView，让外层 `.refreshable` 在空态也响应下拉
            // Follow/Recent 未接入真接口前，store 停在 .idle，view 直接显 Coming soon 空态而非 spinner
            scrollWrap {
                if comingSoonOnEmpty { comingSoonView } else { loadingView }
            }
        case .loaded(let rooms, let hasMore):
            if rooms.isEmpty {
                scrollWrap {
                    if comingSoonOnEmpty { comingSoonView } else { emptyView }
                }
            } else {
                roomList(rooms: rooms, hasMore: hasMore, showBottomLoader: false, pageErrorMessage: nil)
            }
        case .refreshing(let rooms):
            // list-refresh-preserve-items rule：下拉刷新期保留 rooms 视觉，顶部 spinner 由 .refreshable 自身管
            // hasMore 传 true 保持底部 loadMoreSentinel 显示；避免 loaded→refreshing→loaded 时 sentinel 闪烁
            // （loadMore() 内部对 .refreshing 态是 no-op，sentinel onAppear 触发不会重入）
            if rooms.isEmpty {
                // v7：空 rooms + refreshing → 也要走 scrollWrap 保证 refreshable 挂载体
                scrollWrap {
                    if comingSoonOnEmpty { comingSoonView } else { loadingView }
                }
            } else {
                roomList(rooms: rooms, hasMore: true, showBottomLoader: false, pageErrorMessage: nil)
            }
        case .loadingMore(let rooms):
            roomList(rooms: rooms, hasMore: true, showBottomLoader: true, pageErrorMessage: nil)
        case .error(let message, _):
            // v7：error 态也用 scrollWrap 让用户能下拉重试（原来的 Retry Button 保留）
            scrollWrap { errorView(message: message) }
        case .pageError(let rooms, let message):
            roomList(rooms: rooms, hasMore: true, showBottomLoader: false, pageErrorMessage: message)
        }
    }

    /// v7（2026-07-14）非滚动态包 ScrollView 让 `.refreshable` 可响应下拉。
    /// minHeight 让内容居中撑满 tab 内容区（避免小 view 只占顶部一小片下拉手势区域）。
    private func scrollWrap<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, minHeight: 400)
        }
        .scrollIndicators(.hidden)
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
        EmptyStateView(
            style: .full,
            text: L10n.commonNoContent,
            textColor: .white.opacity(0.5)
        )
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
            LazyVStack(spacing: 8) {
                ForEach(rooms, id: \.stableListId) { room in
                    Button {
                        onTapRoom(room)
                    } label: {
                        PartyRoomCardView(
                            room: room,
                            languageName: languageName(for: room.roomLanguage),
                            isMyRoom: room.id == myRoomID
                        )
                        // Top3 背景的装饰边框会越出卡片底部，预留下方空间避免覆盖下一行。
                        .padding(.bottom, hasDecorativeRankBorder(room) ? 8 : 0)
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if hasMore {
                    loadMoreSentinel(showLoader: showBottomLoader, pageErrorMessage: pageErrorMessage)
                }

                Color.clear.frame(height: 32)
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
        }
        .scrollIndicators(.hidden)
    }

    private func languageName(for code: String?) -> String {
        guard let code, !code.isEmpty else { return L10n.Party.languageAll }
        return languages.first(where: { $0.languageCode == code })?.languageName ?? code
    }

    private func hasDecorativeRankBorder(_ room: PartyRoomInfo) -> Bool {
        guard let rank = room.rangIndex else { return false }
        return (1...3).contains(rank)
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

/// H5 `roomList.vue` 的房间卡：64pt 环形封面、86pt 卡高、房型/语言/Top3 标签和右侧热度区。
struct PartyRoomCardView: View {
    let room: PartyRoomInfo
    let languageName: String
    let isMyRoom: Bool

    var body: some View {
        ZStack {
            rankBackground
            HStack(alignment: .center, spacing: 12) {
                cover
                info
                trailingInfo
            }
            .padding(12)
        }
        // 保持列表原有的紧凑行高；`minHeight` 会被信息列内容撑大。
        .frame(height: 100)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: 0x1A1556))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isMyRoom ? .white.opacity(0.5) : .white.opacity(0.14),
                    lineWidth: isMyRoom ? 1 : 0.5
                )
        }
        .overlay(alignment: .topTrailing) {
            if room.lockFlag == 1 {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(10)
                .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topLeading) {
            if isMyRoom {
                HStack(spacing: 3) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(L10n.Party.myRoom)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(
                    LinearGradient(
                        colors: [Color(hex: 0x006AFF), Color(hex: 0x00BFFF)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    /// v17（2026-07-14）房间封面：对齐 H5 `roomList.vue L50`
    /// `<v-image :src="item.roomAvatar" round default-show-type="partyRoom">` —— 读后端 URL 优先，
    /// 空 URL / 加载中 / 失败时 fallback 本地 `partyRoomCover` 默认图（对齐 H5 default-show-type）。
    private var cover: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0xFF9438), Color(hex: 0xFF0091), Color(hex: 0xFE00DE)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 66, height: 66)
            CachedAsyncImage(url: URL(string: room.roomAvatar ?? ""),
                             contentMode: .fill,
                             persistent: true,
                             cdn: (.avatarLarge, .fill)) {
                Image("partyRoomCover")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.black.opacity(0.55), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .frame(width: 64, height: 64)
        }
        .overlay(alignment: .bottom) {
            // H5 封面底部 `party-list-animation.gif`。
            AnimatedGIFView(
                name: "party-list-animation"
            )
            .frame(width: 34, height: 16)
            .padding(.bottom, 6)
            .accessibilityHidden(true)
        }
        .accessibilityHidden(true)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(room.roomName ?? L10n.Party.listUnnamed)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.Palette.partyRoomName)
                .lineLimit(1)

            Text(room.greetingMessage ?? L10n.Party.listWelcomeFallback)
                .font(.system(size: 13))
                .foregroundColor(Theme.Palette.partyGreeting)
                .lineLimit(1)
                .padding(.vertical, 2)

            HStack(spacing: 4) {
                roomTypePill
                pill(text: languageName, color: Color(hex: 0x5924EB), textColor: Color(hex: 0xC5BAFF))
                rankTag
            }
            .frame(height: 16)
            .clipped()

            HStack(spacing: -2) {
                ForEach(previewAvatars(), id: \.self) { url in
                    avatarCircle(url: url)
                }
            }
            .frame(height: 16)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var roomTypePill: some View {
        let isVoiceOnly = room.roomTempType == 1
        let text = isVoiceOnly ? L10n.Party.listPillVoice : L10n.Party.listPillLiveVoice
        return HStack(spacing: 3) {
            Image(systemName: isVoiceOnly ? "mic.fill" : "video.fill")
                .font(.system(size: 8, weight: .bold))
                .frame(width: 10)
            PartyRoomRightToLeftMarquee(
                text: text,
                font: .system(size: 10, weight: .medium),
                foregroundColor: isVoiceOnly ? Color(hex: 0xD7FDCD) : Color(hex: 0xFFE4F4)
            )
        }
        .padding(.horizontal, 5)
        .frame(width: isVoiceOnly ? 60 : 78, height: 16)
        .background(isVoiceOnly ? Color(hex: 0x50B96E) : Color(hex: 0xE045B1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func pill(text: String, color: Color, textColor: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(textColor)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(color)
            .clipShape(Capsule())
    }

    private func previewAvatars() -> [String] {
        let list = room.onlineUserList ?? []
        return list.prefix(4).compactMap { $0.avatar }.filter { !$0.isEmpty }
    }

    private func avatarCircle(url: String) -> some View {
        AvatarView(urlString: url, size: 16, kind: .user)
            .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1))
    }

    @ViewBuilder
    private var rankTag: some View {
        if let rank = room.rangIndex, (1...3).contains(rank) {
            weeklyRankTag(rank: rank)
        }
    }

    private func weeklyRankTag(rank: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 10)
            PartyRoomRightToLeftMarquee(
                text: L10n.Party.listWeeklyTop(rank),
                font: .system(size: 10, weight: .medium),
                foregroundColor: .white.opacity(0.9)
            )
        }
        .foregroundColor(.white.opacity(0.9))
        .padding(.horizontal, 5)
        .frame(height: 16)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: weeklyRankColors(rank: rank),
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .clipShape(Capsule())
    }

    private func weeklyRankColors(rank: Int) -> [Color] {
        switch rank {
        case 1: return [Color(hex: 0x7C5223), Color(hex: 0xD7BB77)]
        case 2: return [Color(hex: 0x2E3166), Color(hex: 0xA8A8D6)]
        default: return [Color(hex: 0x43292F), Color(hex: 0x89685D)]
        }
    }

    @ViewBuilder
    private var rankBackground: some View {
        if let rank = room.rangIndex, let assetName = rankBackgroundAssetName(for: rank) {
            Image(assetName)
                .resizable()
                .scaledToFill()
            .scaleEffect(1.03)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func rankBackgroundAssetName(for rank: Int) -> String? {
        switch rank {
        case 1: return "partyRoomTop1Background"
        case 2: return "partyRoomTop2Background"
        case 3: return "partyRoomTop3Background"
        default: return nil
        }
    }

    private var trailingInfo: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 20)
            Spacer(minLength: 0)
            if room.showChest == true {
                AnimatedGIFView(name: "roomlist-top3-box-new", fileExtension: "webp")
                    .frame(width: 46, height: 38)
            } else {
                Color.clear.frame(width: 46, height: 38)
            }
            heatIndicator.frame(height: 18)
        }
        .frame(width: 60, height: 62)
    }

    private var heatIndicator: some View {
        HStack(spacing: 3) {
            // v5：PK 中房间标识（对齐 H5 roomList.vue L88-89 `pkStatus 1=选队 2=进行中`）
            if let p = room.pkStatus, p > 0 {
                Image("livePkIcon")
                    .resizable().scaledToFit()
                    .frame(width: 14, height: 14)
                    .accessibilityLabel("PK")
            }
            Image("partyIconFire")
                .resizable()
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(heatText)
                .font(.system(size: 13))
                .foregroundColor(Theme.Palette.partyHeatText)
        }
    }

    /// H5 列表直接展示服务端 heatValue；缺值时以 0 维持末列尺寸稳定。
    private var heatText: String {
        "\(room.heatValue ?? 0)"
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
        return PartyRoomListContent(
            store: store,
            languages: [.all, PartyLanguage(languageName: "English", languageCode: "en")],
            myRoomID: nil,
            onTapRoom: { _ in },
            comingSoonOnEmpty: false
        )
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
