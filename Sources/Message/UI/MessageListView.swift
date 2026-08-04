import Combine
import SwiftUI
import UIKit

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
    @ObservedObject private var permission = SelfPermissionBridge.shared
    @StateObject private var massTextingStore = MassTextingStore()
    /// H-2 spec §4.1：短按 row 时把 peerYxAccId 追加到 path 触发 push；由 MainTabView 上抬持有
    @Binding var messagesPath: NavigationPath
    @State private var transientError: String?
    @State private var longPressedSession: MessageSession?
    /// 顶部右 icon 触发的"清空当前 tab"确认对话框
    @State private var showClearTabConfirm: Bool = false
    @State private var isMassTextingHintVisible = false
    @State private var massTextingHintTask: Task<Void, Never>?

    private var topSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
    }

    var body: some View {
        ZStack {
            profileBackgroundLayer
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // 顶部大标题(对齐设计稿 `消息列表-未读已读.png` 左上"News")+ 右上 2 个 icon
                HStack(spacing: 12) {
                    Text(L10n.messageNewsTitle)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    // 左 icon:通话/消息记录切图(Frame 390 日历+时钟)——H5 tap 跳 /communication Records tab
                    if permission.canCall {
                        Button {
                            messagesPath.append(MessageListView.callRecordsSentinel)
                        } label: {
                            CDNAssetImage("messageNavHistory")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    // 右 icon:清空当前 tab 会话列表(切图"清除.png")
                    Button {
                        showClearTabConfirm = true
                    } label: {
                        CDNAssetImage("messageNavClear")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)

                categoryTabBar
                content
            }
        }
        .task {
            if case .idle = store.state {
                await store.load()
            }
        }
        // 对齐 H5 onActivated：每次返回 News 都刷新群发次数，并决定是否展示当天的入口提示。
        .onAppear {
            Task {
                if await massTextingStore.refreshCount() {
                    presentMassTextingHintIfNeeded()
                }
            }
        }
        .onDisappear {
            massTextingHintTask?.cancel()
            massTextingHintTask = nil
            isMassTextingHintVisible = false
        }
        // H5 在浮标提示 4 秒内捕获首个页面点击后打开群发弹窗。
        .overlay {
            if isMassTextingHintVisible {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissMassTextingHint()
                        Task { await massTextingStore.open() }
                    }
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            massTextingFloatingEntry
                .padding(.trailing, 12)
                .padding(.bottom, 114)
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
        .overlay {
            if !massTextingStore.isPresented, let status = massTextingStore.status {
                MassTextingStatusOverlay(status: status) {
                    massTextingStore.dismissStatus()
                }
                .transition(.opacity)
            }
        }
        .sheet(
            isPresented: $massTextingStore.isPresented,
            onDismiss: {
                Task { await massTextingStore.refreshCount() }
            }
        ) {
            MassTextingSheet(store: massTextingStore)
                .presentationDetents([.height(430), .medium])
                .presentationDragIndicator(.visible)
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
        // 顶部右 icon 触发的清空当前 tab 会话确认（对齐 H5 news/index.vue:showEmpty）
        .confirmationDialog(
            L10n.messageClearTabTitle,
            isPresented: $showClearTabConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.messageClearTabConfirm, role: .destructive) {
                Task { await store.clearCategory(store.selectedCategory) }
            }
            Button(L10n.messageActionCancel, role: .cancel) {}
        }
    }

    /// 与 Profile 首页共用顶部背景图、过渡高度和页面底色。
    private var profileBackgroundLayer: some View {
        VStack(spacing: 0) {
            CDNAssetImage("profileTopBg")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Metric.profileHeaderHeight + topSafeAreaInset)
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [Color.clear, Theme.Palette.profileBackground],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 60)
                }
                .clipped()
            Theme.Palette.profileBackground
        }
        .ignoresSafeArea(edges: .top)
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

    /// 顶部右上角 icon 按钮（对齐设计稿右上 2 icon 视觉；tap 弹 "Coming Soon" 占位 —— 业务待接）
    private func topBarIconButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    /// 对齐 H5 bulkMsg：按账号、北京时间最多在连续三天各展示一次 4 秒入口提示。
    private func presentMassTextingHintIfNeeded() {
        guard MassTextingHintSchedule.consumeDisplay(for: SessionStore.shared.user?.userId) else { return }
        massTextingHintTask?.cancel()
        withAnimation { isMassTextingHintVisible = true }
        massTextingHintTask = Task {
            do {
                try await Task.sleep(nanoseconds: 4_000_000_000)
            } catch {
                return
            }
            await MainActor.run {
                withAnimation { isMassTextingHintVisible = false }
                massTextingHintTask = nil
            }
        }
    }

    private func dismissMassTextingHint() {
        massTextingHintTask?.cancel()
        massTextingHintTask = nil
        withAnimation { isMassTextingHintVisible = false }
    }

    private var massTextingFloatingEntry: some View {
        ZStack(alignment: .topTrailing) {
            if isMassTextingHintVisible {
                Text(L10n.massTextingHint)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(width: 142)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(hex: 0x351B54), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .offset(x: -138, y: -24)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            Button {
                dismissMassTextingHint()
                Task { await massTextingStore.open() }
            } label: {
                CDNAssetImage("messageBadgeMassTexting")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 58)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.massTextingTitle)

            if massTextingStore.dailySendLimit > 0 {
                Text(massTextingStore.dailySendLimit > 99 ? "99+" : "\(massTextingStore.dailySendLimit)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color(hex: 0xE40132), in: Capsule())
                    .offset(x: 3, y: -2)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Mass Texting（对齐 H5 bulkMsgPopup.vue）

private enum MassTextingHintSchedule {
    private static let keyPrefix = "message.massTexting.hint"
    private static let shanghaiTimeZone = TimeZone(identifier: "Asia/Shanghai")!

    /// H5 将首次展示日和剩余次数存到 user store；iOS 改用按 userId 隔离的 UserDefaults。
    /// 初次、次日和第三天各展示一次，第三天后不再展示。
    static func consumeDisplay(for userId: Int?) -> Bool {
        guard let userId, userId > 0 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghaiTimeZone
        let today = calendar.startOfDay(for: Date()).timeIntervalSince1970
        let key = "\(keyPrefix).\(userId)"
        let defaults = UserDefaults.standard

        guard let record = defaults.dictionary(forKey: key),
              let firstDay = (record["firstDay"] as? NSNumber)?.doubleValue,
              let remaining = (record["remaining"] as? NSNumber)?.intValue else {
            defaults.set(["firstDay": today, "remaining": 2], forKey: key)
            return true
        }

        let elapsedDays = Int((today - firstDay) / 86_400)
        let nextRemaining: Int?
        switch (elapsedDays, remaining) {
        case (1, 2):
            nextRemaining = 1
        case (2, 2), (2, 1):
            nextRemaining = 0
        default:
            nextRemaining = nil
        }
        guard let nextRemaining else { return false }
        defaults.set(["firstDay": firstDay, "remaining": nextRemaining], forKey: key)
        return true
    }
}

private enum MassTextingStatus: Equatable {
    case success
    case limitReached
    case cooldown(String)
    case refreshUnavailable
    case failed(String)

    var title: String {
        switch self {
        case .success:
            return L10n.massTextingSendSuccess
        case .limitReached:
            return L10n.massTextingDailyLimitReached
        case .cooldown(let message):
            return message
        case .refreshUnavailable:
            return L10n.massTextingRefreshUnavailable
        case .failed(let message):
            return message
        }
    }

    var systemImage: String {
        switch self {
        case .success:
            return "checkmark.circle.fill"
        case .limitReached, .cooldown:
            return "exclamationmark.triangle.fill"
        case .refreshUnavailable, .failed:
            return "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success:
            return Color(hex: 0x47D18C)
        case .limitReached, .cooldown:
            return Color(hex: 0xFFCC00)
        case .refreshUnavailable, .failed:
            return Color(hex: 0xFF5A6A)
        }
    }
}

@MainActor
private final class MassTextingStore: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSending = false
    @Published private(set) var dailySendLimit = 0
    @Published private(set) var refreshCount = 0
    @Published private(set) var copywriting = ""
    @Published private(set) var loadError: String?
    @Published var status: MassTextingStatus?

    private let service: MassTextingServiceProtocol
    private var copywritingId: MassTextingCopywritingID?
    private var statusTask: Task<Void, Never>?

    init(service: MassTextingServiceProtocol = MassTextingService()) {
        self.service = service
    }

    func open() async {
        isPresented = true
        AnalyticsTracker.track("im_mass_entry_click")
        await loadCopywriting(previousId: nil)
    }

    @discardableResult
    func refreshCount() async -> Bool {
        do {
            let count = try await service.fetchDailySendLimit()
            dailySendLimit = count
            return true
        } catch {
            // H5 也把入口次数视为非阻塞信息；失败不影响消息列表主流程。
            return false
        }
    }

    func retryLoad() async {
        await loadCopywriting(previousId: copywritingId)
    }

    @discardableResult
    func refreshCopywriting() async -> Bool {
        guard !isRefreshing, !isLoading else { return false }
        guard refreshCount > 0 else {
            AnalyticsTracker.track("im_mass_refreshcopy_click", properties: ["refresh_type": "refresh_fail"])
            return false
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let response = try await service.fetchCopywriting(excluding: copywritingId)
            apply(response)
            AnalyticsTracker.track("im_mass_refreshcopy_click", properties: ["refresh_type": "refresh_success"])
            return false
        } catch let error as APIError {
            AnalyticsTracker.track("im_mass_refreshcopy_click", properties: ["refresh_type": "refresh_fail"])
            if error.message == "Sorry, message library unavailable. Please refresh later." {
                showStatus(.refreshUnavailable)
                return false
            } else {
                showStatus(.refreshUnavailable)
                return true
            }
        } catch {
            AnalyticsTracker.track("im_mass_refreshcopy_click", properties: ["refresh_type": "refresh_fail"])
            showStatus(.refreshUnavailable)
            return true
        }
    }

    @discardableResult
    func send() async -> Bool {
        guard !isSending else { return false }
        guard dailySendLimit > 0 else {
            AnalyticsTracker.track("send_limit")
            showStatus(.limitReached)
            return true
        }
        guard let copywritingId else {
            showStatus(.failed(L10n.massTextingNoCopywriting))
            return false
        }

        isSending = true
        defer { isSending = false }
        do {
            let response = try await service.send(copywritingId: copywritingId)
            if let updatedLimit = response.dailySendLimit {
                dailySendLimit = updatedLimit
                copywriting = ""
                self.copywritingId = nil
            } else {
                dailySendLimit = max(0, dailySendLimit - 1)
            }
            AnalyticsTracker.track("im_mass_send_success")
            showStatus(.success)
            return true
        } catch let error as APIError {
            AnalyticsTracker.track("send_cooldown")
            showStatus(.cooldown(error.message))
            return true
        } catch {
            showStatus(.failed(L10n.massTextingSendFailed))
            return true
        }
    }

    func dismissStatus() {
        statusTask?.cancel()
        statusTask = nil
        withAnimation { status = nil }
    }

    private func loadCopywriting(previousId: MassTextingCopywritingID?) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let response = try await service.fetchCopywriting(excluding: previousId)
            apply(response)
        } catch let error as APIError {
            loadError = error.message
        } catch {
            loadError = L10n.massTextingLoadFailed
        }
    }

    private func apply(_ response: MassTextingCopywritingResponse) {
        dailySendLimit = response.dailySendLimit
        refreshCount = response.refreshCount
        copywriting = response.copywriting?.content ?? ""
        copywritingId = response.copywriting?.id
        loadError = nil
    }

    private func showStatus(_ nextStatus: MassTextingStatus, duration: UInt64 = 3) {
        statusTask?.cancel()
        withAnimation { status = nextStatus }
        statusTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: duration * 1_000_000_000)
            } catch {
                return
            }
            await MainActor.run {
                withAnimation { self?.status = nil }
            }
        }
    }
}

private protocol MassTextingServiceProtocol {
    func fetchDailySendLimit() async throws -> Int
    func fetchCopywriting(excluding id: MassTextingCopywritingID?) async throws -> MassTextingCopywritingResponse
    func send(copywritingId: MassTextingCopywritingID) async throws -> MassTextingSendResponse
}

private struct MassTextingService: MassTextingServiceProtocol {
    func fetchDailySendLimit() async throws -> Int {
        let data = try await APIClient.shared.post("/api/massMsg/getAnchorDailySendCount", body: [:])
        let response = try JSONDecoder().decode(MassTextingDailyLimitResponse.self, from: data)
        return response.dailySendLimit
    }

    func fetchCopywriting(excluding id: MassTextingCopywritingID?) async throws -> MassTextingCopywritingResponse {
        var body: [String: Any] = [:]
        if let id {
            body["copywritingId"] = id.jsonValue
        }
        let data = try await APIClient.shared.post("/api/massMsg/getCopywriting", body: body)
        return try JSONDecoder().decode(MassTextingCopywritingResponse.self, from: data)
    }

    func send(copywritingId: MassTextingCopywritingID) async throws -> MassTextingSendResponse {
        let data = try await APIClient.shared.post(
            "/api/massMsg/batchSendMsgToUser",
            body: ["copywritingId": copywritingId.jsonValue]
        )
        return (try? JSONDecoder().decode(MassTextingSendResponse.self, from: data)) ?? MassTextingSendResponse(dailySendLimit: nil)
    }
}

private struct MassTextingDailyLimitResponse: Decodable {
    let dailySendLimit: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dailySendLimit = c.decodeFlexibleInt(forKey: .dailySendLimit) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case dailySendLimit
    }
}

private struct MassTextingCopywritingResponse: Decodable {
    let dailySendLimit: Int
    let refreshCount: Int
    let copywriting: MassTextingCopywriting?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dailySendLimit = c.decodeFlexibleInt(forKey: .dailySendLimit) ?? 0
        refreshCount = c.decodeFlexibleInt(forKey: .refreshCount) ?? 0
        copywriting = try c.decodeIfPresent(MassTextingCopywriting.self, forKey: .copywriting)
    }

    private enum CodingKeys: String, CodingKey {
        case dailySendLimit
        case refreshCount
        case copywriting
    }
}

private struct MassTextingCopywriting: Decodable {
    let id: MassTextingCopywritingID?
    let content: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decode(MassTextingCopywritingID.self, forKey: .id)
        content = (try? c.decode(String.self, forKey: .copywritingContent))
            ?? (try? c.decode(String.self, forKey: .content))
            ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case copywritingContent
        case content
    }
}

private struct MassTextingSendResponse: Decodable {
    let dailySendLimit: Int?

    init(dailySendLimit: Int?) {
        self.dailySendLimit = dailySendLimit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dailySendLimit = c.decodeFlexibleInt(forKey: .dailySendLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case dailySendLimit
    }
}

private enum MassTextingCopywritingID: Equatable, Decodable {
    case int(Int64)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let int = try? c.decode(Int64.self) {
            self = .int(int)
        } else if let string = try? c.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "copywriting id is neither int nor string")
        }
    }

    var jsonValue: Any {
        switch self {
        case .int(let value):
            return value
        case .string(let value):
            return value
        }
    }
}

private struct MassTextingSheet: View {
    @ObservedObject var store: MassTextingStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x16002F), Color(hex: 0x32104D)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                header
                content
                sendButton
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 28)

            // 刷新文案库不可用时 H5 保持 popup 打开，状态层必须位于 sheet 内而非父页面底下。
            if let status = store.status {
                MassTextingStatusOverlay(status: status) {
                    store.dismissStatus()
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AvatarView(
                urlString: SessionStore.shared.user?.icon,
                size: 42,
                kind: .anchor,
                disablesTap: true
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.massTextingTitle)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                Text(L10n.massTextingRemainingFormat(store.dailySendLimit))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.messageActionCancel)
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading {
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                Text(L10n.massTextingLoading)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity, minHeight: 190)
        } else if let loadError = store.loadError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color(hex: 0xFFCC00))
                Text(loadError)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                Button(L10n.massTextingRetry) {
                    Task { await store.retryLoad() }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.16), in: Capsule())
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, minHeight: 190)
        } else {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L10n.massTextingContentTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                        Spacer()
                        Button {
                            Task {
                                if await store.refreshCopywriting() {
                                    dismiss()
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .bold))
                                Text("x \(store.refreshCount)")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(store.refreshCount > 0 ? .white : .white.opacity(0.45))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(store.isRefreshing ? 0.22 : 0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isRefreshing)
                        .accessibilityLabel(L10n.massTextingRefreshCopy)
                    }

                    Text(store.copywriting.isEmpty ? L10n.massTextingNoCopywriting : store.copywriting)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, minHeight: 92, alignment: .center)
                        .multilineTextAlignment(.leading)
                        .padding(14)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: 0x7E67EF), Color(hex: 0x9A61E1)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                }

                HStack(spacing: -8) {
                    ForEach(0..<6, id: \.self) { _ in
                        AvatarView(
                            urlString: nil,
                            size: 42,
                            kind: .user,
                            disablesTap: true
                        )
                        .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 2))
                    }
                }
                .accessibilityHidden(true)
            }
        }
    }

    private var sendButton: some View {
        Button {
            Task {
                if await store.send() {
                    dismiss()
                }
            }
        } label: {
            HStack(spacing: 8) {
                if store.isSending {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.85)
                }
                Text(L10n.massTextingSendOneTap)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(sendButtonBackground, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.26), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(store.isLoading || store.isSending || store.loadError != nil)
    }

    private var sendButtonBackground: LinearGradient {
        if store.dailySendLimit > 0 {
            return LinearGradient(
                colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        return LinearGradient(
            colors: [Color(hex: 0x5E3D89), Color(hex: 0x5E3D89)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

private struct MassTextingStatusOverlay: View {
    let status: MassTextingStatus
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            VStack(spacing: 12) {
                Image(systemName: status.systemImage)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(status.tint)
                Text(status.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .frame(width: 280)
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.88), Color(hex: 0x241A02).opacity(0.88)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status.title)
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
