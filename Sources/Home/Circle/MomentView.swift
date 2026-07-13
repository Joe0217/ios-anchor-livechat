import SwiftUI

/// Circle 内 Moment 子 tab 的内容视图 (trial #1 A-spec §4/§5)。
///
/// 接 `MomentFeedStore` (具体 ObservableObject)，但 store 自身只依赖 `CircleServiceProtocol`，
/// 因此 View 间接通过 protocol 接接口、不直接知道生产 service —— 满足 spec 步 1b 约束。
///
/// 状态机各 case 的视觉映射 (spec §4.7 / §5.1 / §5.2 / §5.4)：
/// - `.idle` / `.loadingFirst` → 居中 ProgressView
/// - `.loaded(posts:[], _)` → empty 占位 (§5.2)
/// - `.loaded(posts, _)` → 列表 + 末项触底
/// - `.loadingMore(posts)` → 列表 + 底部 ProgressView
/// - `.loadMoreError(posts)` → 列表 + 底部 retry (不抹掉已加载，§5.4)
/// - `.error` → 居中 error 占位 + retry (§5.1)
struct MomentView: View {
    @ObservedObject var store: MomentFeedStore
    /// 是否显示删除按钮（仅 me 入口为 true，对齐 H5 `circle/me.vue` showDelete=true）。
    var showDelete: Bool = false
    /// 是否显示评论计数（official 入口为 false，对齐 H5 `circle/official.vue` showContent=false）。
    var showComment: Bool = true
    /// 删除回调（仅当 showDelete=true 时由调用方注入有效闭包）。
    /// 当前 trial #1 UI 对齐阶段：按钮显示，业务接入随发布功能里程碑落地。
    var onDeleteTap: ((MomentPost) -> Void)? = nil
    /// 图片/视频大图预览请求向上传递给 CircleView 层的 fullScreenCover binding。
    ///
    /// **不在本 view 层挂 fullScreenCover 的原因**：TabView(.page) 内 3 个 MomentView tag
    /// 各自挂 fullScreenCover 会触发 SwiftUI presentation 竞态 → first-tap self-dismiss。
    /// 由 CircleView 统一挂 1 个 fullScreenCover 是唯一稳定形态。
    var onMediaPreview: ((MediaGalleryContext) -> Void)? = nil

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 加载触发由 CircleView 的 `.onChange(of: cycleStore.currentSub)` 单一入口控制。
    }

    /// A3：ScrollView 常驻单一 identity 槽位，empty/loading/error 通过 `.overlay` 覆盖显示——
    /// 避免 refresh 期间 `state=.loadingFirst`（posts=[]）触发 if/else 分支切换导致 ScrollView dismantle
    /// + 滚动位置丢失 + 所有 cell 重建。命中 [swiftui-camera-preview.md 规则 1](../../../.claude/rules/swiftui-camera-preview.md)
    /// 精神（同 identity 槽位）。
    private var content: some View {
        let posts = store.state.posts
        return ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(posts) { post in
                    MomentPostRow(
                        post: post,
                        onLikeTap: {
                            if let id = post.postId { store.tapLike(postId: id) }
                        },
                        onDeleteTap: showDelete ? { onDeleteTap?(post) } : nil,
                        showComment: showComment,
                        // 点击某图/视频 cell → 向 CircleView 层的 fullScreenCover 传值
                        // 用 DispatchQueue.main.async 延迟一帧避免 SwiftUI Button action 内
                        // press animation 未完成时 present 系统 race。
                        onImageTap: { idx in
                            if let urls = post.imgUrls, !urls.isEmpty {
                                DispatchQueue.main.async {
                                    onMediaPreview?(MediaGalleryContext(urls: urls, startIndex: idx))
                                }
                            }
                        }
                    )
                    .onAppear {
                        if post.id == posts.last?.id, store.state.hasMore {
                            store.loadMore()
                        }
                    }
                }
                // posts 非空时才显示 footer（loadingMore / retry / 已到底）
                if !posts.isEmpty {
                    footerView(footerForCurrentState)
                }
            }
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        // 下拉刷新（对齐 H5 `CPullRefresh` 全刷首页）
        .refreshable {
            store.reload()
            // refreshable 需 async；轻等待让状态机切到 loadingFirst，用户看到刷新反馈
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // A3：ScrollView 保持 identity 稳定；空列表时按 state 显示占位（不 dismantle ScrollView）
        .overlay {
            if posts.isEmpty {
                emptyOverlay
            }
        }
    }

    /// A3：posts 空时按 state 分派占位视图（loading / error / empty）
    @ViewBuilder
    private var emptyOverlay: some View {
        switch store.state {
        case .idle, .loadingFirst:
            loadingCenter
        case .error:
            errorState
        case .loaded, .loadingMore, .loadMoreError:
            emptyState
        }
    }

    /// 当前 state 派生 footer 类型。posts 非空时由 content 显示。
    private var footerForCurrentState: ListFooter {
        switch store.state {
        case .loadingMore: return .loadingMore
        case .loadMoreError: return .loadMoreError
        default: return .none
        }
    }

    // MARK: - 子视图

    private var loadingCenter: some View {
        VStack {
            Spacer()
            ProgressView()
                .tint(.white)
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            EmptyStateView()
            Spacer()
        }
    }

    private var errorState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.yellow.opacity(0.8))
                .accessibilityHidden(true)  // A2：装饰图标，VoiceOver 忽略
            Text(L10n.circleMomentLoadError)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
            Button {
                store.retry()
            } label: {
                Text(L10n.profileRetry)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private enum ListFooter {
        case none, loadingMore, loadMoreError
    }

    @ViewBuilder
    private func footerView(_ footer: ListFooter) -> some View {
        switch footer {
        case .none:
            // hasMore=false → "已到底"；hasMore=true → loadingMore 触底自动转 .loadingMore
            // .loaded(_, hasMore=false) 显示已到底，.loaded(_, hasMore=true) 不显示（等触底）
            if case .loaded(_, false) = store.state {
                Text(L10n.followListEnd)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.vertical, 12)
            }
        case .loadingMore:
            ProgressView()
                .tint(.white)
                .padding(.vertical, 12)
        case .loadMoreError:
            Button {
                store.retry()
            } label: {
                Text(L10n.profileRetry)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct MomentView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // 4.7a/b 含图 vs 无图
            MomentView(store: .preview(state: .loaded(
                posts: [
                    .mock(postId: 1, nickname: "Sarah", textContent: "纯文本帖示例 (无图)",
                          imgUrls: nil, likeFlag: 0, likeCount: 8),
                    .mock(postId: 2, nickname: "Emma", textContent: "单图帖示例",
                          imgUrls: ["https://picsum.photos/300"], likeFlag: 1, likeCount: 24),
                    .mock(postId: 3, nickname: "Liu", textContent: "九宫格示例",
                          imgUrls: Array(repeating: "https://picsum.photos/200", count: 6),
                          likeFlag: 0, likeCount: 88),
                ],
                hasMore: true
            )))
            .previewDisplayName("4.7 loaded — 含图/无图/多图")

            MomentView(store: .preview(state: .loadingFirst))
                .previewDisplayName("loadingFirst")

            MomentView(store: .preview(state: .loaded(posts: [], hasMore: false)))
                .previewDisplayName("5.2 空列表 empty")

            MomentView(store: .preview(state: .loadingMore(posts: [
                .mock(postId: 11, nickname: "Sarah", textContent: "已加载"),
            ])))
            .previewDisplayName("5.x loadingMore（底部 ProgressView）")

            MomentView(store: .preview(state: .loadMoreError(posts: [
                .mock(postId: 12, nickname: "Sarah", textContent: "已加载，下一页失败"),
            ])))
            .previewDisplayName("5.4 loadMoreError（保留 posts + 底部 retry）")

            MomentView(store: .preview(state: .error))
                .previewDisplayName("5.1 首次加载失败 error")
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
#endif
