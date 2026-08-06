import SwiftUI

/// 关注 / 粉丝 / 朋友 三态列表页（蓝本 08 §3.2 / 02-11 §2.2）。
///
/// 入口：ProfileView 的 stats 三个数字点击；带 initial segment 进入。
/// 顶部 segment 切换 / 列表分页 / 下拉刷新（iOS 16 .refreshable）/ 触底加载下一页。
struct FollowListView: View {
    @StateObject private var vm: FollowListViewModel
    @ObservedObject private var permission = SelfPermissionBridge.shared
    @ObservedObject private var customerStore = CustomerServiceIdStore.shared
    @Environment(\.openUserProfile) private var openUserProfile
    @State private var isOpeningSupport = false
    @State private var isShowingServices = false

    private let isConnectionsRoot: Bool
    private let onOpenSupport: ((String) -> Void)?
    private let onOpenBlocklist: (() -> Void)?
    private let onOpenFeedback: (() -> Void)?

    init(initialSegment: FollowSegment = .following,
         isConnectionsRoot: Bool = false,
         onOpenSupport: ((String) -> Void)? = nil,
         onOpenBlocklist: (() -> Void)? = nil,
         onOpenFeedback: (() -> Void)? = nil) {
        _vm = StateObject(wrappedValue: FollowListViewModel(initial: initialSegment))
        self.isConnectionsRoot = isConnectionsRoot
        self.onOpenSupport = onOpenSupport
        self.onOpenBlocklist = onOpenBlocklist
        self.onOpenFeedback = onOpenFeedback
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
        .navigationTitle(isConnectionsRoot ? L10n.tabConnections : "")
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
        .task {
            guard isConnectionsRoot, permission.canSupportMessaging else { return }
            await customerStore.refreshIfNeeded()
        }
    }

    private var supportRow: some View {
        serviceRow(
            icon: "headphones",
            title: L10n.connectionsSupport,
            subtitle: L10n.connectionsSupportSubtitle,
            isLoading: isOpeningSupport,
            isEnabled: permission.canSupportMessaging,
            action: openSupport
        )
    }

    private var blocklistRow: some View {
        serviceRow(
            icon: "person.crop.circle.badge.xmark",
            title: L10n.settingsBlocklist,
            action: { onOpenBlocklist?() }
        )
    }

    private var feedbackRow: some View {
        serviceRow(
            icon: "envelope",
            title: L10n.settingsFeedback,
            action: { onOpenFeedback?() }
        )
    }

    private func serviceRow(icon: String,
                            title: String,
                            subtitle: String? = nil,
                            isLoading: Bool = false,
                            isEnabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.white.opacity(0.1), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading || !isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityLabel(title)
    }

    private func openSupport() {
        guard permission.canSupportMessaging, !isOpeningSupport else { return }
        isOpeningSupport = true
        Task { @MainActor in
            defer { isOpeningSupport = false }
            await customerStore.refreshIfNeeded()
            guard permission.canSupportMessaging,
                  let peer = customerStore.customerYxAccId,
                  !peer.isEmpty else {
                AppToastCenter.shared.show(L10n.connectionsSupportUnavailable)
                return
            }
            onOpenSupport?(peer)
        }
    }

    private var segmentBar: some View {
        HStack(spacing: 0) {
            ForEach(FollowSegment.allCases) { segment in
                let selected = !isShowingServices && vm.selectedSegment == segment
                Button {
                    isShowingServices = false
                    vm.selectedSegment = segment
                } label: {
                    VStack(spacing: 6) {
                        Text(segment.title)
                            .font(.system(size: isConnectionsRoot ? 13 : 15,
                                          weight: selected ? .semibold : .regular))
                            .foregroundColor(selected ? Theme.Palette.brandYellow : .white.opacity(0.7))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
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

            if isConnectionsRoot {
                servicesTabButton
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Theme.Palette.profileBackground)
    }

    @ViewBuilder
    private var content: some View {
        if isConnectionsRoot, isShowingServices {
            servicesContent
        } else {
            relationshipContent
        }
    }

    private var servicesTabButton: some View {
        let selected = isShowingServices
        return Button {
            isShowingServices = true
        } label: {
            VStack(spacing: 6) {
                Text(L10n.connectionsServices)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? Theme.Palette.brandYellow : .white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
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

    private var servicesContent: some View {
        VStack(spacing: 0) {
            supportRow
            Divider().background(Color.white.opacity(0.06)).padding(.leading, 74)
            blocklistRow
            Divider().background(Color.white.opacity(0.06)).padding(.leading, 74)
            feedbackRow
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var relationshipContent: some View {
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
                    onOpenProfile: user.userId.map { userID in
                        { openUserProfile.perform(String(userID)) }
                    },
                    onToggleFollow: permission.canRelationshipActions
                        ? { Task { await vm.toggleFollow(user: user, sourceSegment: vm.selectedSegment) } }
                        : nil
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
        VStack {
            Spacer()
            EmptyStateView()
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
