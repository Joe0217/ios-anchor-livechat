import SwiftUI

/// Live 广场卡片网格（对齐 H5 `views/home/liveList.vue` 卡片 + 分页部分）。
///
/// 只负责 LazyVGrid + 状态分支 + 触底加载；ScrollView / refreshable 由父容器
/// `LiveTabView.liveStream` 承担（父级还要放 notice + banner）。
///
/// **不变量**（`.claude/rules/swiftui-camera-preview.md` 规则 1）：`cardGrid` 落在同一 identity 槽位——
/// hasItems 时 grid，否则按 loadState 分流；避免 loaded → loadingMore 切换重建 LazyVGrid 导致
/// 触底 onAppear 重复触发。
struct LiveStreamGrid: View {
    @ObservedObject var viewModel: LiveStreamViewModel

    var body: some View {
        VStack(spacing: 12) {
            statefulContent
            // footer 挪出 cardGrid.overlay 到 VStack 尾部——原先用 `.offset(y: 32)` 从 overlay
            // 拽出到 grid 底部之外是 hack 结构（overlay 不占父容器空间，短列表时 footer 会贴在
            // 最后一行下方而不是 ScrollView 底部）。挪到这里后走正常布局 flow，
            // footer 内部各 case 已 guard `!items.isEmpty`，空态自然 EmptyView 不占空间
            footerView
            Color.clear.frame(height: 12)
        }
    }

    @ViewBuilder
    private var statefulContent: some View {
        if !viewModel.items.isEmpty {
            cardGrid
        } else {
            switch viewModel.loadState {
            case .idle, .loadingFirstPage:
                centeredLoading
            case .error(let msg):
                errorState(msg)
            case .loaded, .loadingMore:
                emptyState
            }
        }
    }

    private var cardGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: Theme.Metric.liveCardGap),
            GridItem(.flexible(), spacing: Theme.Metric.liveCardGap),
        ], spacing: Theme.Metric.liveCardGap) {
            ForEach(viewModel.items) { anchor in
                LiveStreamCard(anchor: anchor)
                    .onAppear {
                        if anchor.id == viewModel.items.last?.id,
                           viewModel.hasMore,
                           viewModel.loadState == .loaded {
                            Task { await viewModel.loadMore() }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var footerView: some View {
        switch viewModel.loadState {
        case .loadingMore:
            ProgressView()
                .tint(.white)
                .padding(.vertical, 12)
        case .loaded where !viewModel.hasMore && !viewModel.items.isEmpty:
            Text(L10n.liveListEnd)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .padding(.vertical, 12)
        case .error(_) where !viewModel.items.isEmpty:
            Text(L10n.liveListLoadMoreFailed)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .padding(.vertical, 12)
        default:
            EmptyView()
        }
    }

    private var centeredLoading: some View {
        VStack {
            Spacer(minLength: 80)
            ProgressView().tint(.white)
            Spacer()
        }
        .frame(minHeight: 220)
    }

    private var emptyState: some View {
        VStack {
            Spacer(minLength: 80)
            EmptyStateView()
            Spacer()
        }
        .frame(minHeight: 220)
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Spacer(minLength: 80)
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.yellow.opacity(0.8))
            Text(msg)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(L10n.liveListPullToRetry)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
            Spacer()
        }
        .frame(minHeight: 220)
    }
}
