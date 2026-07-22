import SwiftUI

/// v13-v15 遗留（v16 后不再切换 tab 用途）：保留为公共类型供 UserWeeklyRankSheetView 顶层 Tab 用
enum RankSheetTopTab: Hashable {
    case viewers
    case topGifter
}

/// v16 RankSheet 回归 H5 **girlWeeklyRank.vue** 语义：主播收礼周榜
///
/// **入口**：Rank 徽章 (No.X) tap → 打开本 sheet
///
/// **UI 结构对齐 H5 girlWeeklyRank**：
/// - 无双层 Tab（v13-v15 错把 Viewers/Top Gifter 合并进来 → 反悔拆分）
/// - 顶部：主播周榜 banner 图（h5 是多语言 webp，本轮用文字标题代替待补 asset）
/// - 双 Tab：This Week / Last Week（rankType='week'/'lastWeek'）
/// - List Row：Top1/2/3 皇冠图 + 紫色数字(4+) + avatar + nickname + diamond value
/// - 底部主播悬浮条（**仅主播 isHost=true 时显示**）：rank + avatar + nickname + diamond + 距下一名差值
///
/// **v14 行为**：
/// - 禁用底部下拉关闭（`.interactiveDismissDisabled`）—— 只能顶部 X 关闭
/// - 列表内下拉刷新
/// - sheet load 完成后通过 `onRankUpdate` 回填顶部 rank 徽章（对齐 H5 "无推送→查看后更新" fallback）
struct RankSheetView: View {
    @StateObject private var store: RankStore
    @Binding var isPresented: Bool
    private let onRankUpdate: ((Int?) -> Void)?
    private let onUserTap: (String) -> Void

    init(anchorUserId: String,
         isPresented: Binding<Bool>,
         onRankUpdate: ((Int?) -> Void)? = nil,
         onUserTap: @escaping (String) -> Void = { _ in }) {
        self._store = StateObject(wrappedValue: RankStore(anchorUserId: anchorUserId))
        self._isPresented = isPresented
        self.onRankUpdate = onRankUpdate
        self.onUserTap = onUserTap
    }

    var body: some View {
        // v20: 移除 header（title + 关闭 X），只保留 banner + tabs + content + 悬浮条；关闭走系统下拉
        VStack(spacing: 0) {
            bannerTitle
            tabBar
            content
            anchorOwnRankBar
        }
        .background(Color(hex: 0x1A0033).ignoresSafeArea())
        .onAppear {
            store.loadIfNeeded(period: store.selectedPeriod)
        }
        .onChange(of: store.weekState) { newState in
            if case .loaded(let page) = newState {
                onRankUpdate?(page.anchorOwnRank)
            }
        }
    }

    /// v16 girlWeeklyRank banner 区（对齐 H5 h78 w292 主播周榜标题图；本轮用装饰文字代替 asset）
    private var bannerTitle: some View {
        Text(L10n.liveRoomGirlRankBanner)
            .font(.system(size: 20, weight: .heavy))
            .foregroundStyle(
                LinearGradient(colors: [Color(hex: 0xFF9438), Color(hex: 0xFF0090), Color(hex: 0xFE00DE)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .padding(.vertical, 12)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(period: .week, label: L10n.liveRoomRankTabThisWeek)
            tabButton(period: .lastWeek, label: L10n.liveRoomRankTabLastWeek)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func tabButton(period: RankPeriod, label: String) -> some View {
        Button {
            store.selectedPeriod = period
            store.loadIfNeeded(period: period)
        } label: {
            VStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 15,
                                  weight: store.selectedPeriod == period ? .bold : .regular))
                    .foregroundColor(store.selectedPeriod == period ? .white : .white.opacity(0.5))
                Rectangle()
                    .fill(store.selectedPeriod == period ? Color(hex: 0xFFBB02) : .clear)
                    .frame(height: 2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var content: some View {
        Group {
            let state: RankStore.LoadState = store.selectedPeriod == .week
                ? store.weekState : store.lastWeekState
            switch state {
            case .idle, .loading:
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let page):
                if page.entries.isEmpty {
                    emptyView
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(page.entries) { entry in
                                RankRow(entry: entry, onUserTap: onUserTap)
                                Divider().background(Color.white.opacity(0.06))
                            }
                        }
                    }
                    .refreshable {
                        await store.refresh(period: store.selectedPeriod)
                    }
                }
            case .error:
                errorView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        EmptyStateView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Text(L10n.liveRoomRankErrorRetry)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
            Button {
                store.reload(period: store.selectedPeriod)
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

    /// v16 底部主播悬浮条（对齐 H5 girlWeeklyRank L162-186 isHost sticky bottom）
    @ViewBuilder
    private var anchorOwnRankBar: some View {
        let state: RankStore.LoadState = store.selectedPeriod == .week
            ? store.weekState : store.lastWeekState
        if case .loaded(let page) = state {
            let localUser = SessionStore.shared.user
            HStack(spacing: 10) {
                Text(anchorRankText(page.anchorOwnRank))
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(page.anchorOwnRank == nil ? .white.opacity(0.5) : Color(hex: 0xFE00DE))
                    .frame(width: 28)
                AvatarView(urlString: localUser?.icon, size: 40, kind: .user)
                VStack(alignment: .leading, spacing: 3) {
                    Text(localUser?.nickname?.isEmpty == false ? localUser?.nickname ?? L10n.liveRoomRankOwnMe : L10n.liveRoomRankOwnMe)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image("coins")
                            .resizable()
                            .frame(width: 14, height: 14)
                        Text("\(page.anchorIncome)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(hex: 0xFFE000))
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    Text(L10n.liveRoomRankToNext)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                    Image("coins")
                        .resizable()
                        .frame(width: 14, height: 14)
                    Text("\(max(0, page.diffToPrevious ?? 0))")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: 0xFFE000))
                }
            }
            .padding(.horizontal, 15).padding(.vertical, 12)
            .frame(minHeight: 88)
            .background(
                LinearGradient(colors: [Color(hex: 0x130A2A), Color(hex: 0x1D0D49)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .overlay(Rectangle().frame(height: 1).foregroundColor(.white.opacity(0.2)), alignment: .top)
        }
    }

    private func anchorRankText(_ rank: Int?) -> String {
        guard let rank else { return "--" }
        return rank > 100 || rank == -1 ? "100+" : "\(rank)"
    }
}
