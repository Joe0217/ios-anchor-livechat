import SwiftUI

/// Contribution 钻石收益 sheet（对齐 H5 liveContributionPop.vue）
///
/// 结构：顶部本场收入 chip → 双 Tab (Ranking/Record) → 对应列表（分页支持）
struct ContributionSheetView: View {
    @StateObject private var store: ContributionStore
    @Binding var isPresented: Bool

    init(anchorId: String, roomId: String, isPresented: Binding<Bool>) {
        self._store = StateObject(wrappedValue: ContributionStore(anchorId: anchorId, roomId: roomId))
        self._isPresented = isPresented
    }

    var body: some View {
        // v20: 移除 header（title + 关闭 X），关闭走系统下拉手势
        VStack(spacing: 0) {
            incomeChip
            tabBar
            content
        }
        .background(Color(hex: 0x1A0033).ignoresSafeArea())
        .onAppear { store.onSheetAppear() }
    }

    /// 顶部本场收入 chip（对齐 H5 头部大数字显示）
    @ViewBuilder
    private var incomeChip: some View {
        if case .loaded(let page) = store.rankState {
            VStack(spacing: 4) {
                Text(L10n.liveRoomContributionCurrentLiveIncome)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                HStack(spacing: 6) {
                    Image("coins")
                        .resizable().frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    Text("\(page.totalIncome)")
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundColor(Color(hex: 0xFFE600))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12).padding(.bottom, 8)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(tab: .ranking, label: L10n.liveRoomContributionTabRanking)
            tabButton(tab: .record, label: L10n.liveRoomContributionTabRecord)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func tabButton(tab: ContributionTab, label: String) -> some View {
        Button {
            store.selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 15,
                                  weight: store.selectedTab == tab ? .bold : .regular))
                    .foregroundColor(store.selectedTab == tab ? .white : .white.opacity(0.5))
                Rectangle()
                    .fill(store.selectedTab == tab ? Color(hex: 0xFFBB02) : .clear)
                    .frame(height: 2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch store.selectedTab {
        case .ranking: rankingContent
        case .record:  recordContent
        }
    }

    @ViewBuilder
    private var rankingContent: some View {
        switch store.rankState {
        case .idle, .loading:
            ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let page):
            if page.entries.isEmpty {
                emptyStateRanking
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(page.entries) { entry in
                            ContributionRankRow(entry: entry)
                            Divider().background(Color.white.opacity(0.06))
                        }
                    }
                }
            }
        case .error:
            errorState(retry: store.retryRank)
        }
    }

    @ViewBuilder
    private var recordContent: some View {
        switch store.recordState {
        case .idle, .loading:
            ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let records, let hasMore, _):
            recordList(records, hasMore: hasMore, isLoadingMore: false)
        case .loadingMore(let records, _):
            recordList(records, hasMore: true, isLoadingMore: true)
        case .error:
            errorState(retry: store.retryRecords)
        }
    }

    private func recordList(_ records: [GiftRecord], hasMore: Bool, isLoadingMore: Bool) -> some View {
        Group {
            if records.isEmpty {
                emptyStateRecord
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(records) { r in
                            GiftRecordRow(record: r)
                            Divider().background(Color.white.opacity(0.06))
                        }
                        if hasMore {
                            HStack {
                                if isLoadingMore {
                                    ProgressView().tint(.white)
                                } else {
                                    Color.clear.frame(height: 40)
                                        .onAppear { store.loadMoreRecordsIfNeeded() }
                                }
                            }
                            .frame(height: 40)
                        }
                    }
                }
            }
        }
    }

    private var emptyStateRanking: some View {
        EmptyStateView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateRecord: some View {
        EmptyStateView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(retry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(L10n.liveRoomContributionErrorRetry)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
            Button {
                retry()
            } label: {
                Text(L10n.liveRoomRetry)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24).padding(.vertical, 8)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
