import SwiftUI

/// Profile Moment tab：「我的动态」分页列表。
///
/// **同步朋友圈"我"入口的完整交互**（对齐 H5 `mine/index.vue` 的 `<CCircleContent :show-delete="true" :show-content="true">`）：
/// - 状态机 / 分页 / trim / 发布后广播刷新 全部复用共享 [`MomentFeedStore`](../../Home/Circle/MomentFeedStore.swift)（source=.me(userId:)）
/// - cell 复用共享 [`MomentPostRow`](MomentPostRow.swift) 全交互参数：点赞 + 删除按钮 + 评论计数
/// - 图片/视频点击走公共 [`MediaGalleryView`](../../Core/MediaGallery/MediaGalleryView.swift)（由父 ProfileView 挂 `.fullScreenCover`）
///
/// **嵌入约束**：本 view 嵌在 ProfileView 的 ScrollView 内，**内部只出 LazyVStack**，不叠 ScrollView（禁忌）。
/// 触底 loadMore 依 `onAppear` 判 `post == last` 触发。
///
/// **删除动作**：触发本 view 内 `pendingDeletePost` 二次确认 → `MomentFeedStore.deletePost` → 接口成功后 store 悲观移除。
/// 与 [CircleView](../../Home/Circle/CircleView.swift) me 入口同款 pattern；接口对齐 H5 `mine/index.vue:117-125` `postDelete({searchValue:id})`。
struct MomentTabView: View {
    @StateObject private var store: MomentFeedStore
    /// 点击图片/视频时向上传递给 ProfileView 层的 fullScreenCover 触发（对齐 CircleView 模式）。
    /// 见 [swiftui-fullscreencover-hoist.md](../../../.claude/rules/swiftui-fullscreencover-hoist.md)：modal 必须 hoist 到唯一容器层。
    var onMediaPreview: ((MediaGalleryContext) -> Void)?

    /// 删除动态二次确认 pending 项
    @State private var pendingDeletePost: MomentPost?

    init(userId: Int? = nil, onMediaPreview: ((MediaGalleryContext) -> Void)? = nil) {
        let uid = userId ?? SessionStore.shared.user?.userId ?? 0
        _store = StateObject(wrappedValue: MomentFeedStore(source: .me(userId: uid)))
        self.onMediaPreview = onMediaPreview
    }

    var body: some View {
        let posts = store.state.posts
        // maxWidth: .infinity 让 loading/empty/error 三态能居中——
        // ProfileView 外层 VStack 是 `alignment: .leading`（左对齐），紧密尺寸的 ProgressView 会贴左；
        // 撑满宽度后，内部 VStack 默认 center 对齐 + 子居中 —— spinner 才在中间
        VStack(spacing: 12) {
            if posts.isEmpty {
                emptyOverlay
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(posts) { post in
                        MomentPostRow(
                            post: post,
                            onLikeTap: {
                                if let id = post.postId { store.tapLike(postId: id) }
                            },
                            onDeleteTap: {
                                // 触发二次确认（iOS HIG：破坏性动作应加确认）
                                pendingDeletePost = post
                            },
                            showComment: true,
                            onImageTap: { idx in
                                if let urls = post.imgUrls, !urls.isEmpty {
                                    // 延一帧避 Button press animation 与 present 竞态
                                    // 见 [swiftui-fullscreencover-hoist.md](../../../.claude/rules/swiftui-fullscreencover-hoist.md)
                                    DispatchQueue.main.async {
                                        onMediaPreview?(MediaGalleryContext(urls: urls, startIndex: idx))
                                    }
                                }
                            },
                            translation: post.postId.flatMap { store.translations[$0] },
                            onTapTranslate: (post.postId != nil && !(post.textContent ?? "").isEmpty)
                                ? { store.translateIfNeeded(postId: post.postId!, text: post.textContent ?? "") }
                                : nil,
                            isTranslating: post.postId.map { store.pendingTranslateIds.contains($0) } ?? false
                        )
                        .onAppear {
                            if post.id == posts.last?.id, store.state.hasMore {
                                store.loadMore()
                            }
                        }
                    }
                    footer
                }
            }
        }
        .frame(maxWidth: .infinity)
        .task {
            // idempotent：state ≠ .idle 时不重复触发
            store.enterMoment()
        }
        // 删除动态二次确认（与 CircleView me 入口同款 pattern）
        .confirmationDialog(
            L10n.momentDeleteConfirmTitle,
            isPresented: Binding(
                get: { pendingDeletePost != nil },
                set: { newVal in if !newVal { pendingDeletePost = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletePost
        ) { post in
            Button(L10n.momentDeleteConfirmAction, role: .destructive) {
                if let id = post.postId { store.deletePost(postId: id) }
                pendingDeletePost = nil
            }
            Button(L10n.momentDeleteConfirmCancel, role: .cancel) {
                pendingDeletePost = nil
            }
        }
    }

    /// 空/加载/错误态派发（对齐 [MomentView](../../Home/Circle/MomentView.swift) emptyOverlay 语义）
    @ViewBuilder
    private var emptyOverlay: some View {
        switch store.state {
        case .idle, .loadingFirst:
            ProgressView().tint(.white).padding(.vertical, 40)
        case .error:
            errorState
        case .loaded, .loadingMore, .loadMoreError:
            emptyState
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch store.state {
        case .loadingMore:
            ProgressView().tint(.white).padding(.vertical, 12)
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
        case .loaded(_, false):
            Text(L10n.followListEnd)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .padding(.vertical, 12)
        default:
            EmptyView()
        }
    }

    private var emptyState: some View {
        EmptyStateView()
            .padding(.vertical, 50)
    }

    private var errorState: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.yellow.opacity(0.8))
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
        }
        .padding(.vertical, 40)
    }
}
