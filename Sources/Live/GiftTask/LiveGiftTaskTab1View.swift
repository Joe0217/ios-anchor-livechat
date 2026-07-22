import SwiftUI

/// Tab1 Live Gift Task 视图:进度卡 + 送礼历史列表(无限滚动)。
///
/// 对齐 H5 `liveGiftTaskTab.vue`:
/// - 进度卡:h103 w345 rounded-16 p15 + 卡片渐变(90deg rgba(48,41,109,0.3) → rgba(49,36,140,0.3))
/// - 进度条:粉红渐变(参 `LiveGiftProgressBar.liveGiftGradient`)
/// - 历史列表:每行 head-frame + activeTycoon 徽章 + 昵称 + 时间 + 礼物图 x N
///
/// **数据源**(spec §1.1):
/// - 进度:外部 `LiveGiftTaskStore.giftTask?.giftTotal/taskAmount`
/// - 历史:sheet 内 `@ObservedObject historyStore`
struct LiveGiftTaskTab1View: View {
    let giftTask: GiftTaskProgress?
    @ObservedObject var historyStore: LiveGiftTaskHistoryStore
    let anchorId: String
    let onUserTap: (String) -> Void

    var body: some View {
        VStack(spacing: 10) {
            progressCard
            historyCard
        }
        .padding(.horizontal, 15)
        .padding(.top, 20)
        .padding(.bottom, 30)
    }

    // MARK: - 进度卡

    @ViewBuilder
    private var progressCard: some View {
        let currentPoints = giftTask?.giftTotal ?? 0
        let totalPoints = giftTask?.taskAmount ?? 0
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.liveRoomTaskProgressTitle)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Image("liveRoomTaskBadge")
                    .resizable()
                    .frame(width: 24, height: 24)
            }
            HStack(spacing: 0) {
                LiveGiftProgressBar(currentPoints: currentPoints, totalPoints: totalPoints,
                                    innerGradientColors: LiveGiftProgressBar.liveGiftGradient,
                                    initialAnimationDelayNanoseconds: 3_000_000_000)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Image("coins")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                    Text("\(currentPoints)/\(totalPoints)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(.vertical, 12)
            Text(L10n.liveRoomTaskProgressSubtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(2)
        }
        .padding(15)
        .frame(minHeight: 103)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 历史卡

    @ViewBuilder
    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.liveRoomTaskHistoryTitle)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
            historyList
                .frame(height: 200)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var historyList: some View {
        ScrollView {
            switch historyStore.pagingState {
            case .idle, .loading:
                loadingHistory
            case .refreshing(let items) where items.isEmpty:
                loadingHistory
            case .refreshing(let items), .loaded(let items, _), .loadingMore(let items):
                historyRows(items: items, showingFooter: .rowsIndicator)
            case .finished(let items):
                historyRows(items: items, showingFooter: items.isEmpty ? .empty : .noMore)
            case .error(let items, _):
                historyRows(items: items, showingFooter: .error)
            }
        }
        .refreshable { await historyStore.refreshAsync(anchorUserId: anchorId) }
    }

    private var loadingHistory: some View {
        HStack {
            Spacer()
            ProgressView().tint(.white.opacity(0.5))
            Spacer()
        }
        .padding(.vertical, 20)
    }

    private enum FooterState { case rowsIndicator, noMore, empty, error }

    @ViewBuilder
    private func historyRows(items: [IndexedGiftHistoryItem], showingFooter: FooterState) -> some View {
        LazyVStack(spacing: 10) {
            ForEach(items) { indexed in
                LiveGiftHistoryRow(item: indexed.item, onTap: {
                    onUserTap(indexed.item.userId)
                })
                .onAppear {
                    historyStore.loadMoreIfNeeded(currentItem: indexed, anchorUserId: anchorId)
                }
            }
            footer(state: showingFooter)
        }
    }

    @ViewBuilder
    private func footer(state: FooterState) -> some View {
        switch state {
        case .rowsIndicator:
            if case .loadingMore = historyStore.pagingState {
                HStack {
                    Spacer(); ProgressView().tint(.white.opacity(0.5)); Spacer()
                }.padding(.vertical, 8)
            } else {
                EmptyView()
            }
        case .noMore:
            Text(L10n.liveRoomTaskHistoryFinished)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        case .empty:
            Text(L10n.liveRoomTaskHistoryFinished)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        case .error:
            Button {
                historyStore.retry(anchorUserId: anchorId)
            } label: {
                Text(L10n.liveRoomTaskHistoryError)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: 0xFF9438))
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - 卡片背景(90deg 双色渐变)

    private var cardBackground: some View {
        LinearGradient(
            colors: [Color(hex: 0x30296D, opacity: 0.3), Color(hex: 0x31248C, opacity: 0.3)],
            startPoint: .leading, endPoint: .trailing
        )
    }
}

// MARK: - 单条历史行

/// 对齐 H5 liveGiftTaskTab.vue 每行:head-frame 65x65 覆盖 40x40 头像 + activeTycoon + 昵称 + 时间 + 礼物 x N
struct LiveGiftHistoryRow: View {
    let item: GiftHistoryItem
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onTap) {
                AvatarView(urlString: item.icon,
                           size: 40,
                           kind: .user,
                           headwearURL: item.headFrame,
                           headwearRatio: 65 / 40,
                           userId: item.userId,
                           disablesTap: true)
            }
            .buttonStyle(.plain)
            .frame(width: 65, height: 65)
            if item.activeTycoon == true {
                ActiveTycoonBadge(style: .bigRText, size: .small)
            }
            Text(item.nickname.isEmpty ? "Unknown" : item.nickname)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 120, alignment: .leading)
            Spacer(minLength: 4)
            Text(item.formattedTime)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
                .padding(.trailing, 4)
            giftDisplay
        }
    }

    private var giftDisplay: some View {
        HStack(spacing: 2) {
            AsyncImage(url: URL(string: item.giftIcon)) { img in
                img.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Color.clear
            }
            .frame(width: 28, height: 28)
            Text("x \(item.giftNum)")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct LiveGiftTaskTab1View_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            LiveGiftTaskTab1View(
                giftTask: GiftTaskProgress(giftTotal: 1200, taskAmount: 5000),
                historyStore: {
                    let s = LiveGiftTaskHistoryStore()
                    Task { await s.refreshAsync(anchorUserId: "1") }
                    return s
                }(),
                anchorId: "1",
                onUserTap: { _ in }
            )
            .previewDisplayName("Loaded")

            LiveGiftTaskTab1View(
                giftTask: nil,
                historyStore: LiveGiftTaskHistoryStore(service: LiveGiftTaskServiceFakes(mode: .empty)),
                anchorId: "1",
                onUserTap: { _ in }
            )
            .previewDisplayName("Empty")

            LiveGiftTaskTab1View(
                giftTask: GiftTaskProgress(giftTotal: 500, taskAmount: 5000),
                historyStore: LiveGiftTaskHistoryStore(service: LiveGiftTaskServiceFakes(mode: .error("net"))),
                anchorId: "1",
                onUserTap: { _ in }
            )
            .previewDisplayName("Error")
        }
        .frame(height: 400)
        .background(LinearGradient(colors: [Color(hex: 0x17175A), Color(hex: 0x1D0E4C), Color(hex: 0x130A2A)],
                                   startPoint: .topTrailing, endPoint: .bottomLeading))
        .previewLayout(.sizeThatFits)
    }
}
#endif
