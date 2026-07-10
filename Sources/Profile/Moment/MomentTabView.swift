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
/// **删除动作**：与 [CircleView](../../Home/Circle/CircleView.swift):65 一致占位——业务真删除随发布/删除接口里程碑接入。
struct MomentTabView: View {
    @StateObject private var store: MomentFeedStore
    /// 点击图片/视频时向上传递给 ProfileView 层的 fullScreenCover 触发（对齐 CircleView 模式）。
    /// 见 [swiftui-fullscreencover-hoist.md](../../../.claude/rules/swiftui-fullscreencover-hoist.md)：modal 必须 hoist 到唯一容器层。
    var onMediaPreview: ((MediaGalleryContext) -> Void)?

    init(userId: Int? = nil, onMediaPreview: ((MediaGalleryContext) -> Void)? = nil) {
        let uid = userId ?? SessionStore.shared.user?.userId ?? 0
        _store = StateObject(wrappedValue: MomentFeedStore(source: .me(userId: uid)))
        self.onMediaPreview = onMediaPreview
    }

    var body: some View {
        let posts = store.state.posts
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
                                // 占位：删除业务随发布/删除接口里程碑落地（与 CircleView 一致）
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
                            }
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
        .task {
            // idempotent：state ≠ .idle 时不重复触发
            store.enterMoment()
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
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(0.3))
                .accessibilityHidden(true)
            Text(L10n.profileEmptyPlaceholder)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.5))
        }
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
