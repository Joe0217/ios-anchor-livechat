import SwiftUI

/// Profile Moment tab：「我的动态」分页列表。
///
/// 嵌入在 ProfileView 的 contentForSelectedTab 中（非独立页面），ScrollView 已由父提供，
/// 此处用 LazyVStack + 手动触底检测加载下一页。
struct MomentTabView: View {
    @StateObject private var vm = MomentTabViewModel()

    var body: some View {
        VStack(spacing: 12) {
            if vm.posts.isEmpty {
                switch vm.loadState {
                case .loading, .idle:
                    ProgressView()
                        .tint(.white)
                        .padding(.vertical, 40)
                case .error(let msg):
                    errorView(msg)
                case .loaded:
                    emptyView
                }
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(vm.posts) { post in
                        MomentPostRow(post: post)
                            .onAppear {
                                // 触底预拉
                                if post.id == vm.posts.last?.id {
                                    Task { await vm.loadNextPage() }
                                }
                            }
                    }

                    if vm.loadState.isLoading && !vm.posts.isEmpty {
                        ProgressView()
                            .tint(.white)
                            .padding(.vertical, 12)
                    } else if !vm.hasMore && !vm.posts.isEmpty {
                        Text(L10n.followListEnd)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                            .padding(.vertical, 12)
                    }
                }
            }
        }
        .task {
            // 首次进入加载首页
            if vm.posts.isEmpty, vm.loadState == .idle {
                await vm.loadFirstPage()
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(0.3))
            Text(L10n.profileEmptyPlaceholder)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(.vertical, 50)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.yellow.opacity(0.8))
            Text(msg)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Button {
                Task { await vm.loadFirstPage() }
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
