import SwiftUI

/// 黑名单列表页（I-1 spec §6.D）。
///
/// 接入：SettingsView 内 Button `path.append(ProfileRoute.blocklist)`（原 NavigationLink(value:)
/// 因 iOS 16 List 内失效改 programmatic push）+ MainTabView `navigationDestination(for: ProfileRoute.self)` 推入。
///
/// 状态机：见 `BlocklistViewModel` + spec §3。
struct BlocklistView: View {
    @StateObject private var vm: BlocklistViewModel
    @State private var confirmingItem: BlocklistItem?
    /// 触底预拉防抖：记录上次已 prefetch 过的末项 id，避免 List diff 反复触发（review #2）
    @State private var lastPrefetchedId: String?
    @Environment(\.scenePhase) private var scenePhase

    init(vm: BlocklistViewModel? = nil) {
        // 允许注入（Preview / 单测）；runtime 走 .makeRuntime（默认 BlocklistService.shared）
        _vm = StateObject(wrappedValue: vm ?? BlocklistViewModel.makeRuntime())
    }

    var body: some View {
        ZStack {
            Theme.Palette.profileBackground.ignoresSafeArea()
            content
        }
        .navigationTitle(L10n.blocklistTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Palette.profileBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            // spec F-9：每次 view appear 重入都尝试拉首页，VM 内 isLoading 守卫去重（review #1）。
            // 原 `case .idle = vm.loadState` 守卫会让 .error 后重进无法自动重拉。
            if vm.items.isEmpty, !vm.loadState.isLoading {
                await vm.loadFirstPage()
            }
        }
        // R-22 transientError 顶部 2s 自动消失 toast
        .overlay(alignment: .top) { transientErrorToast }
        // 删除二次确认
        .confirmationDialog(
            L10n.blocklistRemoveConfirmTitle,
            isPresented: Binding(
                get: { confirmingItem != nil },
                set: { if !$0 { confirmingItem = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmingItem
        ) { target in
            Button(L10n.blocklistRemoveConfirmAction, role: .destructive) {
                Task { await vm.unblock(target) }
            }
            Button(L10n.blocklistRemoveConfirmCancel, role: .cancel) {}
        } message: { _ in
            Text(L10n.blocklistRemoveConfirmMessage)
        }
        // review #5：scenePhase 切非 active 时关闭 confirmDialog，防止回前台悬挂态
        .onChange(of: scenePhase) { newPhase in
            if newPhase != .active, confirmingItem != nil {
                confirmingItem = nil
            }
        }
        // review #6：view 真正消失时（非 ScenePhase=.background 触发的 onDisappear）清 transientError，
        // 防止下次回到本页时仍显示 stale toast。守卫规约对齐 swiftui-camera-preview.md §6
        .onDisappear {
            guard scenePhase != .background else { return }
            vm.clearTransientError()
        }
    }

    // MARK: - Content（按 loadState + items 派生）

    @ViewBuilder
    private var content: some View {
        if vm.items.isEmpty {
            switch vm.loadState {
            case .idle, .loadingFirstPage:
                centerSpinner
            case .error(let msg):
                errorView(msg: msg)
            case .loaded, .loadingMore:
                emptyView
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(vm.items) { item in
                BlocklistRow(
                    item: item,
                    isPendingRemove: vm.pendingRemoveIds.contains(item.userId),
                    onTapDelete: { confirmingItem = item }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .onAppear {
                    // review #2：触底预拉防抖。仅当 (a) 是末项 (b) hasMore (c) 未在加载
                    // (d) 与上次 prefetch 的末项 id 不同时才触发；VM 内还有 isLoading 守卫兜底
                    guard item.id == vm.items.last?.id,
                          vm.hasMore,
                          !vm.loadState.isLoading,
                          item.id != lastPrefetchedId else { return }
                    lastPrefetchedId = item.id
                    Task { await vm.loadMore() }
                }
            }
            footerRow
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.profileBackground)
        .refreshable {
            // 下拉刷新会让末项 id 变化；reset prefetch 记忆让新末项可再次触底
            lastPrefetchedId = nil
            await vm.loadFirstPage()
        }
    }

    @ViewBuilder
    private var footerRow: some View {
        HStack {
            Spacer()
            if vm.loadState == .loadingMore {
                ProgressView().tint(Theme.Palette.blocklistName)
            } else if !vm.hasMore, !vm.items.isEmpty {
                Text(L10n.blocklistLoadEnd)
                    .font(Theme.Typography.blocklistMeta)
                    .foregroundColor(Theme.Palette.blocklistTertiary)
            } else if let msg = vm.loadState.errorMessage, !vm.items.isEmpty {
                Button {
                    Task { await vm.retry() }
                } label: {
                    // review #15：用 L10n format 拼接，避免硬编码 RTL 不友好的中点
                    Text(L10n.blocklistLoadErrorRetryFormat(message: msg))
                        .font(Theme.Typography.blocklistMeta)
                        .foregroundColor(.red.opacity(0.85))
                }
            }
            Spacer()
        }
        .padding(.vertical, Theme.Metric.blocklistFooterVPadding)
    }

    // MARK: - States

    private var centerSpinner: some View {
        VStack {
            Spacer()
            ProgressView().tint(Theme.Palette.blocklistName)
            Spacer()
        }
    }

    private var emptyView: some View {
        VStack {
            Spacer()
            EmptyStateView(textColor: Theme.Palette.blocklistTertiary, textFont: Theme.Typography.blocklistEmpty)
            Spacer()
        }
    }

    private func errorView(msg: String) -> some View {
        VStack(spacing: Theme.Metric.blocklistErrorVStackSpacing) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Theme.Metric.blocklistErrorIconSize))
                .foregroundStyle(.yellow)
            Text(msg)
                .font(Theme.Typography.blocklistMeta)
                .foregroundColor(Theme.Palette.blocklistErrorMessage)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Metric.blocklistErrorTextHPadding)
            Button {
                Task { await vm.retry() }
            } label: {
                Text(L10n.blocklistLoadErrorRetry)
                    .font(Theme.Typography.blocklistMeta)
                    .foregroundColor(Theme.Palette.blocklistRetryText)
                    .padding(.horizontal, Theme.Metric.blocklistRetryPaddingH)
                    .padding(.vertical, Theme.Metric.blocklistRetryPaddingV)
                    .background(Theme.Palette.blocklistRetryButton, in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    // MARK: - Transient toast（R-22）

    @ViewBuilder
    private var transientErrorToast: some View {
        if let msg = vm.transientError {
            Text(msg)
                .font(Theme.Typography.blocklistToast)
                .foregroundColor(Theme.Palette.blocklistRetryText)
                .padding(.horizontal, Theme.Metric.blocklistToastHPadding)
                .padding(.vertical, Theme.Metric.blocklistToastVPadding)
                .background(Theme.Palette.blocklistToastBackground, in: Capsule())
                .padding(.top, Theme.Metric.blocklistToastTopPadding)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: msg) {
                    // review #4：Task.sleep 被取消时不应继续清掉新 msg 的 transientError。
                    // 改用 try 而非 try? + Task.checkCancellation 显式守卫
                    do {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        try Task.checkCancellation()
                    } catch {
                        return
                    }
                    vm.clearTransientError()
                }
        }
    }
}

#if DEBUG

/// Preview 专用 service：可注入「fetch result / remove result / 延迟」覆盖各态
final class PreviewBlocklistService: BlocklistServiceProtocol {
    let preset: [BlocklistItem]
    let error: APIError?
    let removeError: APIError?
    init(items: [BlocklistItem] = [], error: APIError? = nil, removeError: APIError? = nil) {
        self.preset = items
        self.error = error
        self.removeError = removeError
    }
    func fetchActive(page: Int, size: Int) async throws -> [BlocklistItem] {
        if let e = error { throw e }
        return preset
    }
    func removeBlock(request: BlockOptRequest) async throws {
        if let e = removeError { throw e }
    }
}

@MainActor
private func previewVM(items: [BlocklistItem] = [],
                      error: APIError? = nil,
                      removeError: APIError? = nil) -> BlocklistViewModel {
    BlocklistViewModel(
        service: PreviewBlocklistService(items: items, error: error, removeError: removeError),
        pageSize: 20,
        networkErrorFallback: L10n.blocklistRemoveNetworkError,
        badUserIdFallback: L10n.blocklistRemoveBadUserId
    )
}

#Preview("Loaded - 5 items") {
    let items = (1...5).map {
        BlocklistItem(userId: "\($0)", nickname: "User \($0)", icon: nil,
                      countryId: "Albania", age: 24, yxAccid: "yx_\($0)",
                      gender: 2, userType: 1, createTimeMs: 1_716_595_200_000)
    }
    return NavigationStack {
        BlocklistView(vm: previewVM(items: items))
    }
    .preferredColorScheme(.dark)
}

#Preview("Empty") {
    NavigationStack {
        BlocklistView(vm: previewVM(items: []))
    }
    .preferredColorScheme(.dark)
}

#Preview("Load error") {
    NavigationStack {
        BlocklistView(vm: previewVM(error: APIError(code: "-1", message: "Network timeout")))
    }
    .preferredColorScheme(.dark)
}

#Preview("RTL (ar) - Loaded") {
    let items = (1...3).map {
        BlocklistItem(userId: "\($0)", nickname: "مستخدم \($0)", icon: nil,
                      countryId: "Albania", age: 24, yxAccid: "yx_\($0)",
                      gender: 2, userType: 1, createTimeMs: 1_716_595_200_000)
    }
    return NavigationStack {
        BlocklistView(vm: previewVM(items: items))
    }
    .environment(\.layoutDirection, .rightToLeft)
    .preferredColorScheme(.dark)
}

/// review #22：边界混合 — 有国家无年龄 / 无国家有年龄 / 都缺 / 无日期 / pending 删除
#Preview("Loaded - 边界混合") {
    let items = [
        BlocklistItem(userId: "1", nickname: "Has country only", icon: nil,
                      countryId: "Brazil", age: nil, yxAccid: "yx_1",
                      gender: 2, userType: 1, createTimeMs: 1_716_595_200_000),
        BlocklistItem(userId: "2", nickname: "Has age only", icon: nil,
                      countryId: nil, age: 18, yxAccid: "yx_2",
                      gender: 1, userType: 1, createTimeMs: 1_716_595_200_000),
        BlocklistItem(userId: "3", nickname: "No country no age", icon: nil,
                      countryId: nil, age: 0, yxAccid: "yx_3",
                      gender: 2, userType: 1, createTimeMs: nil),
        BlocklistItem(userId: "4", nickname: "Pending remove", icon: nil,
                      countryId: "Egypt", age: 30, yxAccid: "yx_4",
                      gender: 1, userType: 1, createTimeMs: 1_716_595_200_000),
    ]
    let vm = previewVM(items: items)
    vm.beginPreviewPending(userId: "4")
    return NavigationStack { BlocklistView(vm: vm) }
        .preferredColorScheme(.dark)
}

#Preview("RTL (ar) - Empty") {
    NavigationStack { BlocklistView(vm: previewVM(items: [])) }
        .environment(\.layoutDirection, .rightToLeft)
        .preferredColorScheme(.dark)
}

#endif
