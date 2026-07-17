import SwiftUI

/// Home Live Tab 下的 List 子页（H5 `views/home/userList.vue`）。
/// 顶部固定 Online/Prime segment（不随列表滚动）+ 用户卡片列表 + 状态分支。
///
/// 父 LiveTabView 已提供 LiveTopBar，此处只渲染下方内容（不含顶部子 tab 行）。
/// VM 由父持有（segment / scroll / 分页状态在父级，避免 .list 切走重建丢状态）。
struct LiveListView: View {
    @ObservedObject var viewModel: LiveListViewModel
    /// 段位显示 bridge（订阅 AppConfig.achorHideButton + AnchorInfo.mine）；对齐 H5 anchortCallAuth 语义。
    /// 每行 UserCard 只收 Bool，不各自订阅，减少 publisher 冗余（keep-alive publisher isolation）。
    @StateObject private var callAuth = CallAuthBridge()
    /// 账户级权限（userType 黑名单，全局硬性 gate）。三层防护 UI 侧订阅点。
    @ObservedObject private var permission = SelfPermissionBridge.shared

    /// 组合规则（P spec §2.4）：
    /// - userType 黑名单命中 → 一律不显示（permission.canCall == false 短路）
    /// - 未命中黑名单 → prime segment 强制显示（H5 show-video="true"），online 走 callAuth.canCall
    private var showVideoCall: Bool {
        permission.canCall && (viewModel.segment == .prime || callAuth.canCall)
    }

    var body: some View {
        VStack(spacing: 0) {
            // segment 钉在顶部，不随下方列表滚动
            LiveListSegmentSwitcher(selected: $viewModel.segment)
                .padding(.horizontal, Theme.Metric.liveScreenMargin)
                .padding(.top, 10)
                .padding(.bottom, 8)

            // refreshable 挂 ScrollView：下拉刷新；卡片末项 onAppear 承载触底加载
            ScrollView {
                VStack(spacing: 14) {
                    statefulContent
                        .padding(.horizontal, Theme.Metric.liveScreenMargin)

                    Color.clear.frame(height: 12)
                }
                .padding(.top, 6)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await viewModel.loadFirstPage()
            }
        }
        // 首次加载由父级 LiveTabView 控制（见 `triggerListLazyLoadIfNeeded`）——
        // keep-alive 架构下 view tree 永久持有，不能用 .task 触发首次加载（启动即预热）。
    }

    /// 按状态机分支渲染：首屏 loading / 卡片列表（含底部 footer）/ 空 / 错误。
    ///
    /// **不变量**（[.claude/rules/swiftui-camera-preview.md](.claude/rules/swiftui-camera-preview.md) 规则 1）：
    /// `cardList` 必须落在**同一 identity 槽位**，否则 loadMore 触底时 .loaded → .loadingMore 的状态切换
    /// 会让 SwiftUI 把不同 switch case 的 cardList 视为不同位置 → dismantle LazyVStack 重建 →
    /// 所有可视行 onAppear 重新触发 → 触底 Task 可能重复 spawn + footer 闪烁。
    /// 用 if/else 让 hasItems 路径下 cardList 永远在同一位置；空态再按 loadState 分流。
    @ViewBuilder
    private var statefulContent: some View {
        if !viewModel.items.isEmpty {
            cardList   // 同一位置承载所有非空态（loaded / loadingMore / loadMoreError）
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

    private var cardList: some View {
        LazyVStack(spacing: Theme.Metric.liveListCardGap) {
            ForEach(viewModel.items) { anchor in
                LiveListUserCard(anchor: anchor, showVideoCall: showVideoCall)
                    .onAppear {
                        // 触底加载：最后一项 onAppear + hasMore + 非错误态
                        if anchor.id == viewModel.items.last?.id,
                           viewModel.hasMore,
                           viewModel.loadState == .loaded {
                            Task { await viewModel.loadMore() }
                        }
                    }
            }
            footerView
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
            // 触底加载失败：仅展示提示，引导用户下拉刷新；不要 retry 按钮（错误态点了无反馈感）
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
    }

    private var emptyState: some View {
        VStack {
            Spacer(minLength: 80)
            EmptyStateView()
            Spacer()
        }
    }

    /// 首屏错误态：去掉 retry 按钮，引导用户用下拉刷新触发重试（更自然 + 反馈明确）。
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
    }
}

#if DEBUG
struct LiveListView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            LiveListView(viewModel: .preview(items: [
                LiveListAnchor(userId: "1", nickname: "Garrett", icon: nil, userLevel: "5",
                               vipExpireTimeMs: nil, country: "Canada", yxAccid: "a1"),
                LiveListAnchor(userId: "2", nickname: "Sarah", icon: nil, userLevel: "12",
                               vipExpireTimeMs: Int64(Date().timeIntervalSince1970 * 1000) + 86_400_000,
                               country: "USA", yxAccid: "a2"),
            ]))
            .previewDisplayName("已加载 2 条（含 VIP）")

            LiveListView(viewModel: .preview(items: [], loadState: .loadingFirstPage))
                .previewDisplayName("loadingFirst（空列表）")

            LiveListView(viewModel: .preview(items: [], loadState: .loaded))
                .previewDisplayName("空列表 empty")

            LiveListView(viewModel: .preview(items: [], loadState: .error("Network error")))
                .previewDisplayName("error（空列表）")
        }
        .background(Theme.Palette.liveBottomDark)
        .preferredColorScheme(.dark)
    }
}
#endif
