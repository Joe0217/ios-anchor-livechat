import SwiftUI

/// 关注 / 粉丝 / 朋友 三态列表页（蓝本 08 §3.2 / 02-11 §2.2）。
///
/// 入口：ProfileView 的 stats 三个数字点击；带 initial segment 进入。
/// 顶部 segment 切换 / 列表分页 / 下拉刷新（iOS 16 .refreshable）/ 触底加载下一页。
struct FollowListView: View {
    @StateObject private var vm: FollowListViewModel
    @Environment(\.dismiss) private var dismiss

    init(initialSegment: FollowSegment = .following) {
        _vm = StateObject(wrappedValue: FollowListViewModel(initial: initialSegment))
    }

    var body: some View {
        ZStack {
            Theme.Palette.profileBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                segmentBar
                Divider().background(Color.white.opacity(0.06))
                content
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Palette.profileBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task(id: vm.selectedSegment) {
            // segment 切换时若未加载过，拉第一页
            if vm.currentState.users.isEmpty, vm.currentState.loadState == .idle {
                await vm.loadFirstPage()
            }
        }
    }

    private var segmentBar: some View {
        HStack(spacing: 0) {
            ForEach(FollowSegment.allCases) { segment in
                let selected = vm.selectedSegment == segment
                Button {
                    vm.selectedSegment = segment
                } label: {
                    VStack(spacing: 6) {
                        Text(segment.title)
                            .font(.system(size: 15, weight: selected ? .semibold : .regular))
                            .foregroundColor(selected ? Theme.Palette.brandYellow : .white.opacity(0.7))
                        Capsule()
                            .fill(Theme.Palette.brandYellow)
                            .frame(width: 22, height: 2)
                            .opacity(selected ? 1 : 0)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Theme.Palette.profileBackground)
    }

    @ViewBuilder
    private var content: some View {
        let state = vm.currentState

        if state.users.isEmpty {
            switch state.loadState {
            case .loading, .idle:
                centerSpinner
            case .error(let msg):
                errorView(msg: msg)
            case .loaded:
                emptyView
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(vm.currentState.users) { user in
                FollowUserRow(
                    user: user,
                    isPending: user.userId.map { vm.pendingFollowUserIds.contains($0) } ?? false,
                    onToggleFollow: {
                        Task { await vm.toggleFollow(user: user) }
                    }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                .onAppear {
                    // 触底预拉：最后一项出现时拉下一页
                    if user.id == vm.currentState.users.last?.id {
                        Task { await vm.loadNextPage() }
                    }
                }
            }

            // 底部加载/到底/错误提示
            footerRow
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.profileBackground)
        .refreshable {
            await vm.loadFirstPage()
        }
        // transient toast：toggleFollow 失败时显示 2 秒，然后自动清空
        .overlay(alignment: .top) {
            if let msg = vm.transientError {
                Text(msg)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.7), in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: msg) {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await MainActor.run { vm.transientError = nil }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.transientError)
    }

    @ViewBuilder
    private var footerRow: some View {
        let state = vm.currentState
        HStack {
            Spacer()
            if state.loadState.isLoading && !state.users.isEmpty {
                ProgressView().tint(.white)
            } else if !state.hasMore && !state.users.isEmpty {
                Text(L10n.followListEnd)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            } else if let msg = state.loadState.errorMessage {
                Button {
                    Task { await vm.retry() }
                } label: {
                    Text("\(msg) · \(L10n.profileRetry)")
                        .font(.system(size: 12))
                        .foregroundColor(.red.opacity(0.85))
                }
            }
            Spacer()
        }
        .padding(.vertical, 16)
    }

    private var centerSpinner: some View {
        VStack {
            Spacer()
            ProgressView().tint(.white)
            Spacer()
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.2.slash")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.3))
            Text(L10n.followListEmpty)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
            Spacer()
        }
    }

    private func errorView(msg: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.yellow)
            Text(msg)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                Task { await vm.retry() }
            } label: {
                Text(L10n.profileRetry)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }
}
