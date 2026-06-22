import SwiftUI

/// Home Live Tab 下的 List 子页（"主播端/list/online"）。
/// 顶部 Online/Prime 切换 + Invite friends banner + 用户卡片列表。
/// 父 LiveTabView 已提供 LiveTopBar，此处只渲染下方内容（不含顶部子 tab 行）。
///
/// **VM 由父 LiveTabView 持有并传入**：LiveTabView 的 `switch selectedSubTab` 在切回
/// Live 子 tab 时会销毁 LiveListView，若 VM 内嵌 @StateObject 会丢 segment/scroll 状态。
struct LiveListView: View {
    @ObservedObject var viewModel: LiveListViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                LiveListSegmentSwitcher(selected: $viewModel.segment)
                    .padding(.horizontal, Theme.Metric.liveScreenMargin)
                    .padding(.top, 10)

                LiveListInviteBanner()
                    .padding(.horizontal, Theme.Metric.liveScreenMargin)

                cardList
                    .padding(.horizontal, Theme.Metric.liveScreenMargin)

                Color.clear.frame(height: 12)
            }
        }
        .scrollIndicators(.hidden)
    }

    private var cardList: some View {
        LazyVStack(spacing: Theme.Metric.liveListCardGap) {
            ForEach(viewModel.users) { user in
                LiveListUserCard(user: user)
            }
        }
    }
}

#Preview {
    LiveListView(viewModel: LiveListViewModel())
        .background(Theme.Palette.liveBottomDark)
        .preferredColorScheme(.dark)
}
