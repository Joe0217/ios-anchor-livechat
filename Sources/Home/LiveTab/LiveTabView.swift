import SwiftUI

/// Home 默认子页：直播流广场。
/// 当前仅 Live 子 tab 有内容，其余 3 个为占位空壳。
/// 数据全部占位，点击无真实业务响应，后续 PR 再接入。
struct LiveTabView: View {
    @StateObject private var viewModel = LiveTabViewModel()

    var body: some View {
        // 用 .background modifier 而非 ZStack 装载背景：
        // ZStack 子视图 ignoresSafeArea 时会把 ZStack 整体撑到全屏，
        // 导致 content 失去顶部 safe area + 吃掉 MainTabView 给 TabBar 的 bottom inset。
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                backgroundLayer
            }
            .preferredColorScheme(.dark)
    }

    /// 整页背景：底层径向晕染切图 + 上方渐变叠层增加层次感。
    /// 仅顶部扩展到状态栏，**不**扩到底部，避免覆盖 MainTabView 的 TabBar。
    private var backgroundLayer: some View {
        ZStack {
            Theme.Palette.liveBottomDark
            Image("liveBackground")
                .resizable()
                .scaledToFill()
                .opacity(0.95)
            LinearGradient(
                colors: [Color.clear, Theme.Palette.liveBottomDark.opacity(0.85)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .clipped()
        .ignoresSafeArea(edges: .top)
    }

    private var content: some View {
        VStack(spacing: 0) {
            LiveTopBar(selected: $viewModel.selectedSubTab, rankCount: viewModel.rankCount)
                .padding(.top, 6)

            switch viewModel.selectedSubTab {
            case .live:
                liveStream
            case .list, .match, .cysle:
                placeholderTab
            }
        }
    }

    /// Live 子 tab 主体：通知条 + banner + 卡片网格，可纵向滚动。
    private var liveStream: some View {
        ScrollView {
            VStack(spacing: 12) {
                LiveNoticeBar(data: viewModel.notice)
                    .padding(.horizontal, Theme.Metric.liveScreenMargin)
                    .padding(.top, 10)

                LiveBanner(data: viewModel.banner)
                    .padding(.horizontal, Theme.Metric.liveScreenMargin)

                cardGrid
                    .padding(.horizontal, Theme.Metric.liveScreenMargin)
                    .padding(.top, 4)

                // 底部预留高度，避免最后一行被自定义 TabBar 遮挡
                Color.clear.frame(height: 12)
            }
        }
        .scrollIndicators(.hidden)
    }

    /// 2 列网格。LazyVGrid 适配后续接入分页加载。
    private var cardGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: Theme.Metric.liveCardGap),
            GridItem(.flexible(), spacing: Theme.Metric.liveCardGap),
        ]
        return LazyVGrid(columns: columns, spacing: Theme.Metric.liveCardGap) {
            ForEach(viewModel.cards) { card in
                LiveCard(card: card)
            }
        }
    }

    private var placeholderTab: some View {
        VStack {
            Spacer()
            Text(L10n.liveSubTabComingSoon)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
        }
    }
}

#Preview {
    LiveTabView()
}
