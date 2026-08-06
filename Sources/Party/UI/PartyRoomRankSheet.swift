import SwiftUI

/// 派对房顶栏 Rank / Viewers sheet（对齐房内贡献、荣耀和在线观众榜）。
///
/// 贡献/荣耀榜支持日、周、月与当前/上一周期切换；荣耀榜不提供月榜。
/// 在线观众列表按服务端 `score` 游标分页，避免一次取完大房间的全部成员。
struct PartyRoomRankSheet: View {
    let initialMode: PartyRoomRankMode
    let roomId: String
    /// 由房间根容器在当前 sheet 完全关闭后消费，避免在 sheet 层内竞争呈现层级。
    let onUserTap: (UserCardPreview) -> Void

    @StateObject private var store: PartyRankStore
    @ObservedObject private var permission = SelfPermissionBridge.shared
    @Environment(\.dismiss) private var dismiss
    /// 点击用户后先关闭当前 UIKit sheet；只有 sheet 真正离场后才通知房间根视图展示名片卡。
    /// 自定义名片卡 overlay 无法跨越仍在展示的 UIKit sheet 层级。
    @State private var selectedUserCardPreview: UserCardPreview?

    init(
        initialMode: PartyRoomRankMode,
        roomId: String,
        onUserTap: @escaping (UserCardPreview) -> Void = { _ in }
    ) {
        self.initialMode = initialMode
        self.roomId = roomId
        self.onUserTap = onUserTap
        _store = StateObject(wrappedValue: PartyRankStore(initialMode: initialMode, roomId: roomId))
    }

    private var canShowValueRankings: Bool {
        permission.canVirtualItems && permission.canGiftSending
    }

    private var canShowCurrentMode: Bool {
        store.mode == .viewers || canShowValueRankings
    }

    var body: some View {
        Group {
            if canShowCurrentMode {
                rankSheetContent
            } else {
                Color.clear.onAppear(perform: dismissIfValueRankingsAreDisabled)
            }
        }
        .onChange(of: canShowValueRankings, perform: handleValueRankingPermissionChange)
        .onDisappear(perform: presentSelectedUserCardAfterDismissal)
    }

    private var rankSheetContent: some View {
        VStack(spacing: 0) {
            header
            switch store.mode {
            case .contribution, .honor, .gameTask:
                rankTabs
                rankFilters
                listContent
            case .viewers:
                listContent
            }
        }
        .background(Color(hex: 0x1A0033).ignoresSafeArea())
        .task { await store.load() }
        // 仅按可见榜单类型和统计周期记录曝光；翻页、刷新、当前/上一期切换不增加噪声。
        .task(id: "\(store.mode.rawValue)-\(store.timeframe.rawValue)") {
            reportRankExposure()
        }
    }

    private func handleValueRankingPermissionChange(_ allowed: Bool) {
        guard !allowed, store.mode != .viewers else { return }
        dismissIfValueRankingsAreDisabled()
    }

    private func dismissIfValueRankingsAreDisabled() {
        guard store.mode != .viewers, !canShowValueRankings else { return }
        store.clearForDisabledValueRankings()
        dismiss()
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        switch store.mode {
        case .viewers:
            Text(L10n.PartyRoom.rankViewersTitle)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 20)
                .padding(.bottom, 16)
        case .contribution, .honor, .gameTask:
            Spacer().frame(height: 12)
        }
    }

    // MARK: - Rank tabs and filters

    private var rankTabs: some View {
        HStack(spacing: 24) {
            rankTabButton(mode: .contribution, label: L10n.PartyRoom.rankTabContribution)
            rankTabButton(mode: .honor, label: L10n.PartyRoom.rankTabHonor)
            rankTabButton(mode: .gameTask, label: L10n.PartyRoom.rankTabGameTask)
            Spacer()
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 16)
    }

    private func rankTabButton(mode: PartyRoomRankMode, label: String) -> some View {
        Button {
            store.switchMode(mode)
        } label: {
            VStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(store.mode == mode ? .white : .white.opacity(0.5))
                Rectangle()
                    .fill(store.mode == mode ? Color(hex: 0xFE00DE) : .clear)
                    .frame(width: 10, height: 3)
                    .cornerRadius(1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rankFilters: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(store.availableTimeframes) { timeframe in
                    Button {
                        store.selectTimeframe(timeframe)
                    } label: {
                        Text(timeframe.label)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(store.timeframe == timeframe ? .white : .white.opacity(0.5))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(
                                Capsule()
                                    .fill(store.timeframe == timeframe
                                        ? Color(hex: 0xFE00DE)
                                        : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Capsule().fill(.black.opacity(0.5)))

            if store.supportsPeriodFilter {
                HStack {
                    countdown
                    Spacer(minLength: 12)
                    Button {
                        store.togglePeriod()
                    } label: {
                        HStack(spacing: 4) {
                            Text(store.period.label(for: store.timeframe))
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var countdown: some View {
        if let endDate = store.countdownEndDate {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if endDate > context.date {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 11, weight: .semibold))
                        Text(Self.remainingTimeText(until: endDate, now: context.date))
                            .monospacedDigit()
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.3)))
                }
            }
        }
    }

    private static func remainingTimeText(until endDate: Date, now: Date) -> String {
        let seconds = max(0, Int(endDate.timeIntervalSince(now)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        return String(format: "%02dD:%02dH:%02dM", days, hours, minutes)
    }

    private func reportRankExposure() {
        guard canShowValueRankings else { return }
        switch store.mode {
        case .contribution:
            PartyAnalytics.track(
                "party_contributionRank",
                properties: ["roomId": roomId, "cycle": store.timeframe.rawValue]
            )
        case .honor:
            PartyAnalytics.track(
                "party_honorRank",
                properties: ["roomId": roomId, "cycle": store.timeframe.rawValue]
            )
        case .viewers:
            PartyAnalytics.track("partyRoom_onlineView_view", properties: ["roomId": roomId])
        case .gameTask:
            break
        }
    }

    // MARK: - List content

    @ViewBuilder
    private var listContent: some View {
        if store.isLoading && store.entries.isEmpty {
            ProgressView().tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.entries.isEmpty {
            emptyView
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                            entryRow(entry: entry, rank: entry.rankIndex ?? index + 1)
                                .onAppear {
                                    if index == store.entries.count - 1 {
                                        store.loadNextPage()
                                    }
                                }
                            Divider().background(Color.white.opacity(0.06))
                        }
                        if store.isLoadingMore {
                            ProgressView()
                                .tint(.white)
                                .padding(.vertical, 16)
                        }
                    }
                    .padding(.top, 4)
                }
                .refreshable { await store.load() }

                if store.mode != .viewers, let myRank = store.myRank {
                    Divider().background(Color.white.opacity(0.2))
                    entryRow(entry: myRank, rank: myRank.rankIndex)
                }
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: store.mode == .viewers ? "person.3.fill" : "trophy")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.3))
            Text(store.mode == .viewers ? L10n.PartyRoom.rankEmptyViewers : L10n.PartyRoom.rankEmptyRank)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Rank row

    private func entryRow(entry: PartyRankEntry, rank: Int?) -> some View {
        Button {
            openUserCard(entry.userCardPreview)
        } label: {
            HStack(spacing: 12) {
                rankBadge(rank)
                AvatarView(urlString: entry.avatar, size: 40, kind: .user, userId: entry.userId)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.nickname ?? "")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let age = entry.age, age > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: entry.gender == 2 ? "figure.stand.dress" : "figure.stand")
                                .font(.system(size: 10))
                            Text("\(age)")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((entry.gender == 2 ? Color(hex: 0xFF1AA7) : Color(hex: 0x205FFF))
                            .clipShape(Capsule()))
                    }
                }
                Spacer(minLength: 8)
                trailingValue(for: entry)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openUserCard(_ preview: UserCardPreview) {
        guard !preview.userId.isEmpty else { return }
        guard selectedUserCardPreview == nil else { return }
        selectedUserCardPreview = preview
        dismiss()
    }

    private func presentSelectedUserCardAfterDismissal() {
        guard let preview = selectedUserCardPreview else { return }
        selectedUserCardPreview = nil
        onUserTap(preview)
    }

    @ViewBuilder
    private func rankBadge(_ rank: Int?) -> some View {
        switch rank ?? -1 {
        case 1:
            Image(systemName: "crown.fill")
                .foregroundColor(Color(hex: 0xFFBB02))
                .font(.system(size: 20))
                .frame(width: 24)
        case 2:
            Image(systemName: "crown.fill")
                .foregroundColor(Color(hex: 0xC0C0C0))
                .font(.system(size: 18))
                .frame(width: 24)
        case 3:
            Image(systemName: "crown.fill")
                .foregroundColor(Color(hex: 0xCD7F32))
                .font(.system(size: 16))
                .frame(width: 24)
        case let value where value > 3:
            Text("\(value)")
                .foregroundColor(Color(hex: 0xA56FF8))
                .font(.system(size: 16, weight: .heavy))
                .frame(width: 24)
        default:
            Text("-")
                .foregroundColor(.white.opacity(0.5))
                .font(.system(size: 16, weight: .heavy))
                .frame(width: 24)
        }
    }

    /// 右侧数值 / 角色徽章：贡献为钻石，荣耀为宝石，在线观众展示 owner/admin 徽章。
    @ViewBuilder
    private func trailingValue(for entry: PartyRankEntry) -> some View {
        switch store.mode {
        case .contribution:
            if let value = entry.rankValue {
                HStack(spacing: 4) {
                    CDNAssetImage("coins")
                        .resizable()
                        .frame(width: 14, height: 14)
                    Text(PartyNumberFormat.compact(value))
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(Color(hex: 0xFFE600))
            }
        case .honor:
            if let value = entry.rankValue {
                HStack(spacing: 4) {
                    CDNAssetImage("gems")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                    Text(PartyNumberFormat.compact(value))
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(Color(hex: 0xA4E4FF))
            }
        case .gameTask:
            if let value = entry.rankValueText, !value.isEmpty {
                HStack(spacing: 4) {
                    CDNAssetImage("coins")
                        .resizable()
                        .frame(width: 14, height: 14)
                    Text(value)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundColor(Color(hex: 0xFFE600))
            }
        case .viewers:
            PartyRoleBadge(roomRoleType: entry.roomRoleType, size: 16)
        }
    }
}

// MARK: - Mode and filter enums

enum PartyRoomRankMode: String, Hashable, Identifiable {
    case contribution
    case honor
    case gameTask
    case viewers

    var id: String { rawValue }
}

enum PartyRankTimeframe: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: L10n.PartyRoom.rankTabDaily
        case .week: L10n.commonWeekly
        case .month: L10n.commonMonthly
        }
    }
}

enum PartyRankPeriod: String {
    case current = "CURRENT"
    case last = "LAST"

    func label(for timeframe: PartyRankTimeframe) -> String {
        switch (self, timeframe) {
        case (.current, .day): L10n.PartyRoom.rankPeriodToday
        case (.last, .day): L10n.PartyRoom.rankPeriodYesterday
        case (.current, .week): L10n.commonThisWeek
        case (.last, .week): L10n.commonLastWeek
        case (.current, .month): L10n.commonThisMonth
        case (.last, .month): L10n.commonLastMonth
        }
    }
}

// MARK: - Sheet store

@MainActor
final class PartyRankStore: ObservableObject {
    @Published private(set) var mode: PartyRoomRankMode
    @Published private(set) var timeframe: PartyRankTimeframe = .day
    @Published private(set) var period: PartyRankPeriod = .current
    @Published private(set) var entries: [PartyRankEntry] = []
    @Published private(set) var myRank: PartyRankEntry?
    @Published private(set) var countdownEndDate: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false

    private let roomId: String
    private let viewerPageSize = 10
    private let gameTaskPageSize = 30
    private var canLoadMore = false
    private var nextViewerOffset: String?
    private var nextGameTaskPage = 1
    /// 每个请求都有递增版本；切榜、切周期或手动刷新时旧响应不会覆盖新状态。
    private var loadSeq = 0

    private var canUseValueRankings: Bool {
        SelfPermissionBridge.shared.canVirtualItems && SelfPermissionBridge.shared.canGiftSending
    }

    private var canUseCurrentMode: Bool {
        mode == .viewers || canUseValueRankings
    }

    init(initialMode: PartyRoomRankMode, roomId: String) {
        self.mode = initialMode
        self.roomId = roomId
    }

    var availableTimeframes: [PartyRankTimeframe] {
        switch mode {
        case .honor, .gameTask:
            return [.day, .week]
        case .contribution:
            return PartyRankTimeframe.allCases
        case .viewers:
            return []
        }
    }

    var supportsPeriodFilter: Bool {
        mode == .contribution || mode == .honor
    }

    func switchMode(_ newMode: PartyRoomRankMode) {
        guard canUseValueRankings else {
            clearForDisabledValueRankings()
            return
        }
        guard mode != newMode else { return }
        mode = newMode
        if (newMode == .honor || newMode == .gameTask), timeframe == .month {
            timeframe = .day
        }
        resetContent()
        Task { await load() }
    }

    func selectTimeframe(_ newTimeframe: PartyRankTimeframe) {
        guard canUseValueRankings else {
            clearForDisabledValueRankings()
            return
        }
        guard timeframe != newTimeframe else { return }
        timeframe = newTimeframe
        period = .current
        resetContent()
        Task { await load() }
    }

    func togglePeriod() {
        guard canUseValueRankings else {
            clearForDisabledValueRankings()
            return
        }
        period = period == .current ? .last : .current
        resetContent()
        Task { await load() }
    }

    func load() async {
        await fetch(reset: true)
    }

    func loadNextPage() {
        guard canUseCurrentMode else {
            clearForDisabledValueRankings()
            return
        }
        guard (mode == .viewers || mode == .gameTask), canLoadMore, !isLoading, !isLoadingMore else { return }
        Task { await fetch(reset: false) }
    }

    /// 对权限撤销的统一收口：取消旧响应资格，并移除已经缓存的榜单/个人名次。
    func clearForDisabledValueRankings() {
        guard mode != .viewers, !canUseValueRankings else { return }
        resetContent()
    }

    private func resetContent() {
        loadSeq &+= 1
        entries = []
        myRank = nil
        countdownEndDate = nil
        canLoadMore = false
        nextViewerOffset = nil
        nextGameTaskPage = 1
        isLoading = false
        isLoadingMore = false
    }

    private func fetch(reset: Bool) async {
        guard canUseCurrentMode else {
            clearForDisabledValueRankings()
            return
        }
        if !reset, ((mode != .viewers && mode != .gameTask) || !canLoadMore || isLoading || isLoadingMore) {
            return
        }

        let requestMode = mode
        let requestTimeframe = timeframe
        let requestPeriod = period
        let viewerOffset = reset ? nil : nextViewerOffset
        let gameTaskPage = reset ? 1 : nextGameTaskPage
        let currentSeq = { loadSeq &+= 1; return loadSeq }()

        if reset {
            entries = []
            myRank = nil
            countdownEndDate = nil
            canLoadMore = false
            nextViewerOffset = nil
            nextGameTaskPage = 1
            isLoading = true
        } else {
            isLoadingMore = true
        }

        do {
            switch requestMode {
            case .contribution:
                let response = try await PartyAPI.partyContributionRank(
                    roomId: roomId,
                    rankType: requestTimeframe.rawValue,
                    periodType: requestPeriod == .last ? requestPeriod.rawValue : nil
                )
                guard isCurrentRequest(currentSeq) else { return }
                entries = response.rankList
                myRank = response.myRank
                countdownEndDate = response.duration.map { Date().addingTimeInterval(TimeInterval($0)) }
            case .honor:
                let response = try await PartyAPI.partyHonorRank(
                    roomId: roomId,
                    rankType: requestTimeframe.rawValue,
                    periodType: requestPeriod == .last ? requestPeriod.rawValue : nil
                )
                guard isCurrentRequest(currentSeq) else { return }
                entries = response.rankList
                myRank = response.myRank
                countdownEndDate = response.duration.map { Date().addingTimeInterval(TimeInterval($0)) }
            case .gameTask:
                let response = try await PartyAPI.gameTaskRanking(
                    type: requestTimeframe.rawValue,
                    page: gameTaskPage,
                    size: gameTaskPageSize
                )
                guard isCurrentRequest(currentSeq) else { return }
                if reset {
                    entries = response.list
                } else {
                    let existingIds = Set(entries.map(\.userId))
                    entries.append(contentsOf: response.list.filter { !existingIds.contains($0.userId) })
                }
                myRank = response.myRanking
                nextGameTaskPage = gameTaskPage + 1
                canLoadMore = !response.list.isEmpty && entries.count < response.total
            case .viewers:
                let page = try await PartyAPI.partyOnlineViewers(
                    roomId: roomId,
                    pageSize: viewerPageSize,
                    offset: viewerOffset
                )
                guard isCurrentRequest(currentSeq) else { return }
                if reset {
                    entries = page
                } else {
                    let existingIds = Set(entries.map(\.userId))
                    entries.append(contentsOf: page.filter { !existingIds.contains($0.userId) })
                }
                nextViewerOffset = page.last?.score
                canLoadMore = page.count == viewerPageSize && nextViewerOffset != nil
            }
        } catch {
            guard currentSeq == loadSeq else { return }
            guard canUseCurrentMode else {
                clearForDisabledValueRankings()
                return
            }
            AppLogger.party.error(
                "[PartyRankStore] load failed mode=\(String(describing: requestMode), privacy: .public) err=\(String(describing: error), privacy: .public)"
            )
            if reset {
                entries = []
                myRank = nil
                countdownEndDate = nil
            }
            canLoadMore = false
        }

        guard currentSeq == loadSeq else { return }
        guard canUseCurrentMode else {
            clearForDisabledValueRankings()
            return
        }
        isLoading = false
        isLoadingMore = false
    }

    private func isCurrentRequest(_ sequence: Int) -> Bool {
        guard sequence == loadSeq else { return false }
        guard canUseCurrentMode else {
            clearForDisabledValueRankings()
            return false
        }
        return true
    }
}
