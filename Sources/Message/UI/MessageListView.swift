import Combine
import SwiftUI

/// P2P 会话列表主 view（H-1 MVP，v3 UI 对齐 H5）。
///
/// **架构**：
/// - 顶部自定义 3 tab bar（Flame / Prime / Stranger，标题旁附未读数 badge）
/// - 内容用 `TabView(.page)` 承载 swipe 手势切换（对齐 H5 v-swiper 手感）
/// - 长按 row → `.confirmationDialog` bottom sheet 承载 Unpin/Delete（对齐 H5 van-popup）
/// - 空态：SF Symbol tray 大图 + "No Data" 文案
/// - Store 订阅 `provider.isConnectedPublisher` 自动等 IM 登录后 load（Step 3 反悔 #1 修复）
struct MessageListView: View {

    @ObservedObject var store: MessageSessionStore
    /// H-2 spec §4.1：短按 row 时把 peerYxAccId 追加到 path 触发 push；由 MainTabView 上抬持有
    @Binding var messagesPath: NavigationPath
    @State private var transientError: String?
    @State private var longPressedSession: MessageSession?

    var body: some View {
        VStack(spacing: 0) {
            // 顶部大标题（对齐设计稿 `消息列表-未读已读.png` 左上"News"）
            HStack {
                Text(L10n.messageNewsTitle)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                // 右上角占位 icon 位（日程 / 礼盒）—— 具体功能未接（关联 CP Task / Mass Texting 独立业务）
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)

            categoryTabBar
            content
        }
        .task {
            if case .idle = store.state {
                await store.load()
            }
        }
        .overlay(alignment: .top) {
            if let err = transientError {
                Text(err)
                    .font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.black.opacity(0.75), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        // Bottom sheet：长按会话弹置顶/删除 confirmation
        .confirmationDialog(
            longPressedSession?.peerNickname ?? "",
            isPresented: Binding(
                get: { longPressedSession != nil },
                set: { if !$0 { longPressedSession = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let s = longPressedSession {
                Button(s.isTop ? L10n.messageActionUnstickTop : L10n.messageActionStickTop) {
                    Task { await handleStickTop(s) }
                }
                Button(L10n.messageActionDelete, role: .destructive) {
                    Task { await handleDelete(s) }
                }
                Button(L10n.messageActionCancel, role: .cancel) {}
            }
        }
    }

    // MARK: - 顶部 tab bar（对齐设计稿 `消息列表-未读已读.png` 彩色胶囊 + 99+ badge overlay）

    private var categoryTabBar: some View {
        HStack(spacing: 10) {
            ForEach(MessageSessionCategory.allCases, id: \.self) { cat in
                tabButton(cat)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// 设计稿:
    /// - selected: 紫粉渐变胶囊 + 白粗字（黄字 Flame）
    /// - unselected: 深紫底 + 白 50% opacity 字
    /// - 未读 99+ badge: 橙红胶囊 overlay 到右上角
    private func tabButton(_ cat: MessageSessionCategory) -> some View {
        let selected = store.selectedCategory == cat
        let unread = store.unreadCount(in: cat)
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                store.selectedCategory = cat
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Text(label(for: cat))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? Color(hex: 0xFFE24C) : Color.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background {
                        if selected {
                            Capsule().fill(
                                LinearGradient(colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                        } else {
                            Capsule().fill(Color(hex: 0x3B2B58).opacity(0.6))
                        }
                    }

                if unread > 0 {
                    Text(unread > 99 ? "99+" : "\(unread)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(
                            LinearGradient(colors: [Color(hex: 0xFF9826), Color(hex: 0xFE6828)],
                                           startPoint: .leading, endPoint: .trailing),
                            in: Capsule()
                        )
                        .offset(x: 4, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func label(for cat: MessageSessionCategory) -> String {
        switch cat {
        case .flame:    return L10n.messageCategoryFlame
        case .stranger: return L10n.messageCategoryStranger
        case .prime:    return L10n.messageCategoryPrime
        }
    }

    // MARK: - 内容：TabView(.page) swipe

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading:
            loadingState
        case .error(let msg):
            errorState(msg)
        case .loaded:
            pageContent
        }
    }

    private var loadingState: some View {
        VStack {
            Spacer()
            ProgressView()
            Spacer()
        }
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Button(L10n.messageLoadErrorRetry) {
                Task { await store.retry() }
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding()
        .accessibilityLabel(L10n.messageLoadErrorRetry)
    }

    private var pageContent: some View {
        // Tab 顺序对齐 H5 list.vue：Flame → Prime → Stranger（H5 news/message/index.vue tab 定义顺序）
        TabView(selection: $store.selectedCategory) {
            categoryPage(.flame).tag(MessageSessionCategory.flame)
            categoryPage(.prime).tag(MessageSessionCategory.prime)
            categoryPage(.stranger).tag(MessageSessionCategory.stranger)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    @ViewBuilder
    private func categoryPage(_ cat: MessageSessionCategory) -> some View {
        let sessions = store.sessions(in: cat)
        // Flame page 顶部固定 3 系统消息入口（v4 对齐 H5 list.vue #before slot）
        // 3 入口本身即内容 → 常规 sessions 空时**不显示**"No hot conversations yet"空态（问题 1 修复）
        if cat == .flame {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.systemInboxEntries) { entry in
                        SystemInboxRow(entry: entry) {
                            handleSystemInboxTap(entry)
                        }
                        Divider().padding(.leading, 76)
                    }
                    ForEach(sessions) { session in
                        MessageSessionRow(
                            session: session,
                            profile: store.profile(for: session.id),
                            onLongPress: { longPressedSession = session },
                            onTap: { messagesPath.append(session.id) }
                        )
                        Divider().padding(.leading, 76)
                    }
                }
            }
            .refreshable { await store.load() }
        } else {
            if sessions.isEmpty {
                emptyState(for: cat)
            } else {
                listView(sessions)
            }
        }
    }

    private func emptyState(for category: MessageSessionCategory) -> some View {
        // 消息 tab 是浅色背景，用 .secondary 自适应文案色（旧行为保留 category-无关的统一占位）
        VStack {
            Spacer()
            EmptyStateView(textColor: .secondary, textFont: .subheadline)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func listView(_ sessions: [MessageSession]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sessions) { session in
                    MessageSessionRow(
                        session: session,
                        profile: store.profile(for: session.id),
                        onLongPress: { longPressedSession = session },
                        onTap: { messagesPath.append(session.id) }
                    )
                    Divider().padding(.leading, 76)
                }
            }
        }
        .refreshable { await store.load() }
    }

    // MARK: - Actions

    /// 系统消息 3 入口点击：
    /// - `.station` HTTP 独立列表页 → push StationListView（用 sentinel string 走 MainTabView 分支）
    /// - `.notification` P2P 会话 → push messagesPath（yxAccId = AppConfig.notificationYxAccId）
    /// - `.admin` P2P 会话 → push messagesPath（yxAccId = CustomerServiceIdStore.customerYxAccId）
    private func handleSystemInboxTap(_ entry: SystemInboxEntry) {
        switch entry.kind {
        case .station:
            store.markStationRead()
            messagesPath.append(MessageListView.stationSentinel)
        case .notification:
            messagesPath.append(AppConfig.notificationYxAccId)
        case .admin:
            guard let cid = CustomerServiceIdStore.shared.customerYxAccId, !cid.isEmpty else {
                showTransientError(L10n.messageSystemInboxComingSoon)
                return
            }
            messagesPath.append(cid)
        }
    }

    /// Batch 3.8：Station 详情页 sentinel（MainTabView.navigationDestination 分支识别）
    static let stationSentinel = "__station_list__"
    /// 通话历史记录页 sentinel（对齐 H5 `/communication?from=news&active=0` 的 Records tab）
    static let callRecordsSentinel = "__call_records__"

    private func handleStickTop(_ session: MessageSession) async {
        let beforeState = store.state
        await store.setStickTop(sessionId: session.id, isTop: !session.isTop)
        if beforeState == store.state {
            showTransientError(L10n.messageActionFailedToast)
        }
    }

    private func handleDelete(_ session: MessageSession) async {
        await store.delete(sessionId: session.id)
        if store.currentSessions.contains(where: { $0.id == session.id }) {
            showTransientError(L10n.messageActionFailedToast)
        }
    }

    private func showTransientError(_ text: String) {
        withAnimation { transientError = text }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { transientError = nil }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct MessageListView_Previews: PreviewProvider {

    @MainActor
    final class PreviewProvider_: MessageSessionProviderProtocol {
        var stubSessions: [MessageSession] = []
        var stubError: Error?
        func fetchAll() async throws -> [MessageSession] {
            if let e = stubError { throw e }
            return stubSessions
        }
        func setStickTop(sessionId: String, isTop: Bool) async throws {}
        func delete(sessionId: String) async throws {}
        func subscribe(_ handler: @MainActor @escaping (MessageSessionEvent) -> Void) {}
        func unsubscribe() {}
        var isConnectedPublisher: AnyPublisher<Bool, Never> {
            Just(true).eraseToAnyPublisher()
        }
    }

    @MainActor
    final class PreviewPrime: PrimeLevelProviderProtocol {
        var stub: Set<String> = []
        func fetchPrime(yxAccIds: [String]) async -> Set<String> { stub.intersection(yxAccIds) }
    }

    @MainActor
    final class PreviewStation: StationListProviderProtocol {
        var stubMail: StationMail?
        func fetchLatest() async -> StationMail? { stubMail }
        func isUnread(_ mail: StationMail) -> Bool { true }
        func markRead(_ mail: StationMail) {}
    }

    @MainActor
    final class PreviewProfile: ConversationProfileProviderProtocol {
        var stub: [String: ConversationProfile] = [:]
        func fetch(yxAccIds: [String]) async -> [String: ConversationProfile] {
            var out: [String: ConversationProfile] = [:]
            for id in yxAccIds { if let p = stub[id] { out[id] = p } }
            return out
        }
    }

    @MainActor
    final class PreviewCustomer: CustomerServiceIdProviderProtocol {
        private let subject: CurrentValueSubject<String?, Never>
        init(id: String? = nil) { subject = CurrentValueSubject(id) }
        var customerYxAccId: String? { subject.value }
        var customerYxAccIdPublisher: AnyPublisher<String?, Never> { subject.eraseToAnyPublisher() }
        func refreshIfNeeded() async {}
        func clear() { subject.send(nil) }
    }

    @MainActor
    static func makeStore(sessions: [MessageSession], prime: Set<String> = [], error: Error? = nil,
                          stationMail: StationMail? = nil) -> MessageSessionStore {
        let p = PreviewProvider_()
        p.stubSessions = sessions
        p.stubError = error
        let primeP = PreviewPrime()
        primeP.stub = prime
        let stationP = PreviewStation()
        stationP.stubMail = stationMail
        return MessageSessionStore(
            provider: p,
            primeProvider: primeP,
            stationProvider: stationP,
            customerServiceStore: PreviewCustomer(),
            profileProvider: PreviewProfile()
        )
    }

    static let sample: [MessageSession] = [
        .init(id: "flame1", peerNickname: "Alice", peerAvatarURL: nil,
              lastMessage: "Hi!", lastMessageTimestamp: Int64(Date().timeIntervalSince1970 * 1000),
              unreadCount: 3, isTop: true,
              ext: MessageSessionExt(receivedGift: true, called: false, received: false, sended: false)),
        .init(id: "prime1", peerNickname: "Bob", peerAvatarURL: nil,
              lastMessage: "[Gift]", lastMessageTimestamp: Int64(Date().timeIntervalSince1970 * 1000) - 3600_000,
              unreadCount: 0, isTop: false, ext: .empty),
        .init(id: "str1", peerNickname: "Carol", peerAvatarURL: nil,
              lastMessage: "hello", lastMessageTimestamp: Int64(Date().timeIntervalSince1970 * 1000) - 86400_000,
              unreadCount: 99, isTop: false, ext: .empty),
    ]

    static var previews: some View {
        Group {
            MessageListView(store: makeStore(sessions: sample, prime: ["prime1"]), messagesPath: .constant(NavigationPath()))
                .previewDisplayName("Loaded 3 categories")
            MessageListView(store: makeStore(sessions: []), messagesPath: .constant(NavigationPath()))
                .previewDisplayName("Empty (Flame)")
            MessageListView(store: makeStore(sessions: [], error: NSError(domain: "preview", code: -1)), messagesPath: .constant(NavigationPath()))
                .previewDisplayName("Error retry")
        }
    }
}
#endif
