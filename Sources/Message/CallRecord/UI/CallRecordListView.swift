import SwiftUI

/// 通话历史记录列表页 —— 对齐 H5 `views/communication/index.vue` 的 Records tab。
///
/// **入口**：MessageListView 顶部导航"通话记录" icon 触发 push（sentinel string 路由）。
///
/// **对齐 H5**：
/// - 顶部标题 "Communication"（H5 `CNavBar :title="$t('message.Communication')"`）
/// - 单一列表 tab（H5 页面还含 Following/Followers，iOS 已由 UserProfile 覆盖，此处只做通话记录）
/// - 分页 20/页；`.refreshable` 下拉；触底加载更多；空态 + 无更多提示
/// - Row：头像 + 昵称 + 等级/VIP + 来源标签 + 通话状态胶囊 + 时间戳
struct CallRecordListView: View {

    @StateObject private var store: CallRecordStore
    /// 承载 push UserProfileRoute（沿用外层 tab NavigationStack）
    @Binding var path: NavigationPath

    init(store: CallRecordStore = CallRecordStore(), path: Binding<NavigationPath>) {
        _store = StateObject(wrappedValue: store)
        _path = path
    }

    var body: some View {
        // ⚠️ 布局关键：content 走**正常 safe area inset**（自动让出 nav bar 高度 44pt +
        // status bar），背景走 `.background` modifier 独立 ignoresSafeArea 撑满全屏。
        //
        // 之前用 ZStack + 3 层子 view 各自 ignoresSafeArea 会破坏 safe area 从 NavigationStack
        // 传给 ScrollView 的语义 → ScrollView 视为全屏起点 = 第一行钻到 nav bar 下方被遮挡。
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack {
                    Color(hex: 0x1A0F2E)
                    CDNAssetImage("messageListBackground")
                        .resizable()
                        .scaledToFill()
                        .allowsHitTesting(false)
                }
                .ignoresSafeArea()
            }
            .navigationTitle(L10n.callRecordListTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color(hex: 0x1A0F2E), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .task { await store.loadIfNeeded() }
    }

    // MARK: - Content 分支
    //
    // ⚠️ 关键：**所有"含 items"的态共享同一分支**，避免 SwiftUI 因 switch case 变化重建 ScrollView，
    // 导致滑到底触发 loadMore（state → .loadingMore）时 ScrollView 身份重生 → 滚动位置回顶部。
    // 参见 [swiftui-camera-preview.md](../../.claude/rules/swiftui-camera-preview.md) §1 view identity 稳定性。

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading:
            loadingView
        case .error(let msg):
            errorView(msg)
        case .loaded, .refreshing, .loadingMore, .pageError:
            // 4 态共享 listContent 分支 —— ScrollView 身份不重生，滚动位置保持
            listContent
        }
    }

    /// 有 items 的稳定分支：从 store.state 抽取衍生态（不用 switch），ScrollView 身份稳定
    @ViewBuilder
    private var listContent: some View {
        let items = store.state.items
        if items.isEmpty {
            emptyView
        } else {
            listBody(
                items: items,
                hasMore: store.state.hasMore,
                isLoadingMore: isCurrentlyLoadingMore,
                pageErrorMessage: currentPageErrorMessage
            )
        }
    }

    private var isCurrentlyLoadingMore: Bool {
        if case .loadingMore = store.state { return true }
        return false
    }

    private var currentPageErrorMessage: String? {
        if case .pageError(_, let msg) = store.state { return msg }
        return nil
    }

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView().tint(.white)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityHidden(true)
            Text(msg)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button(L10n.messageLoadErrorRetry) {
                Task { await store.retry() }
            }
            .buttonStyle(.bordered)
            .tint(.white)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - List body

    @ViewBuilder
    private func listBody(items: [CallRecord],
                          hasMore: Bool,
                          isLoadingMore: Bool,
                          pageErrorMessage: String?) -> some View {
        if items.isEmpty {
            emptyView
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, record in
                        CallRecordRow(record: record) {
                            handleTap(record)
                        }
                        // 分割线（对齐 H5 border-bottom 0.5px rgba(255,255,255,0.10)）
                        Divider()
                            .background(Color.white.opacity(0.10))
                            .padding(.leading, 76)

                        // 触底监听：倒数第 3 行出现即触发 loadMore（比"最后一行"更平滑）
                        if hasMore, index == items.count - 3 {
                            Color.clear.frame(height: 1)
                                .onAppear { store.loadMore() }
                        }
                    }

                    footer(items: items, hasMore: hasMore, isLoadingMore: isLoadingMore, pageErrorMessage: pageErrorMessage)
                }
            }
            .refreshable { await store.refreshAsync() }
        }
    }

    @ViewBuilder
    private func footer(items: [CallRecord],
                        hasMore: Bool,
                        isLoadingMore: Bool,
                        pageErrorMessage: String?) -> some View {
        if isLoadingMore {
            HStack(spacing: 8) {
                ProgressView().tint(.white.opacity(0.7))
                Text(L10n.callRecordLoadingMore)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else if let msg = pageErrorMessage {
            VStack(spacing: 6) {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                Button(L10n.messageLoadErrorRetry) {
                    Task { await store.refreshAsync() }
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.vertical, 12)
        } else if !hasMore, !items.isEmpty {
            Text(L10n.callRecordNoMoreData)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
    }

    private var emptyView: some View {
        VStack {
            Spacer()
            EmptyStateView(text: L10n.callRecordEmpty,
                           textColor: .white.opacity(0.6))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    /// Tap row → 跳用户详情（对齐 H5 `goToUserDetail(item)` → `router.push('/userProfile')`）
    private func handleTap(_ record: CallRecord) {
        let userId = record.userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userId.isEmpty else { return }
        path.append(UserProfileRoute.userId(userId))
    }
}

#if DEBUG
struct CallRecordListView_Previews: PreviewProvider {

    static let sampleSuccess = mockRecord(
        userId: "1001", nickname: "Alice",
        source: "matchV4", missedReason: 4, callerUserType: 1,
        duration: 125, createTime: nowMs()
    )
    static let sampleRejected = mockRecord(
        userId: "1002", nickname: "Bob",
        source: "liveCall", missedReason: 1, callerUserType: 0,
        duration: 0, createTime: nowMs() - 60 * 60 * 1000
    )
    static let sampleTimeout = mockRecord(
        userId: "1003", nickname: "Carol",
        source: "private", missedReason: 2, callerUserType: 1,
        duration: 0, createTime: nowMs() - 24 * 60 * 60 * 1000
    )

    static var previews: some View {
        Group {
            NavigationStack {
                CallRecordListView(
                    store: makePreviewStore(state: .loaded(items: [sampleSuccess, sampleRejected, sampleTimeout], hasMore: false)),
                    path: .constant(NavigationPath())
                )
            }
            .previewDisplayName("Loaded 3 records")

            NavigationStack {
                CallRecordListView(
                    store: makePreviewStore(state: .loaded(items: [], hasMore: false)),
                    path: .constant(NavigationPath())
                )
            }
            .previewDisplayName("Empty")

            NavigationStack {
                CallRecordListView(
                    store: makePreviewStore(state: .loading),
                    path: .constant(NavigationPath())
                )
            }
            .previewDisplayName("Loading")

            NavigationStack {
                CallRecordListView(
                    store: makePreviewStore(state: .error("Network unreachable")),
                    path: .constant(NavigationPath())
                )
            }
            .previewDisplayName("Error")
        }
    }

    @MainActor
    private static func makePreviewStore(state: CallRecordStore.State) -> CallRecordStore {
        let store = CallRecordStore(fetcher: { _, _ in [] })
        store._debugSetState(state)
        return store
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private static func mockRecord(userId: String, nickname: String, source: String,
                                   missedReason: Int, callerUserType: Int,
                                   duration: Int, createTime: Int64) -> CallRecord {
        let json: [String: Any] = [
            "userId": userId,
            "nickname": nickname,
            "userLevelName": "35",
            "vipExpireTime": Int64(Date().timeIntervalSince1970 + 86400) * 1000,
            "source": source,
            "missedReason": missedReason,
            "callerUserType": callerUserType,
            "duration": duration,
            "createTime": createTime,
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(CallRecord.self, from: data)
    }
}
#endif
