import SwiftUI

/// 派对房「Blocklist」sheet（房主/管理员视角）— 对齐 H5
/// `livechat-h5/src/components/party/components/blocklist.vue`。
///
/// spec §3 + list-refresh-preserve-items rule：
/// - `.task` 首次拉取（reason=.initial）→ `.loading`
/// - `.refreshable` 下拉刷新走 `store.refreshBlocklist()`：closure 必须 await 到任务完成
///   （list-refresh-preserve-items rule B），期间 store 转 `.refreshing(items)` 保留视觉
/// - 单项移除走 confirmationDialog 二次确认（与 H5 差异化：H5 无差别弹成功，本 sheet 失败走 error toast）
struct PartyBlocklistSheet: View {
    @ObservedObject var store: PartyStore

    /// 二次确认弹窗当前对象；nil = 未弹窗
    @State private var pendingRemoval: PartyBlocklistItem?
    /// 全局 toast（成功/失败共用，isError 决定语义；视觉复用 toastStyle 单一来源）
    @State private var toast: ToastMessage?
    /// 首次挂载时间戳 —— 供限时封禁 row 的 TimelineView 计算剩余秒数
    /// （spec §3 + verify P1 #1 fix：改 Store 层 Timer 为 UI 层 TimelineView 减少复杂度）
    @State private var fetchedAt: Date = Date()

    /// 局部 toast 载体 — 携 id 供 `.task(id:)` 复触发计时
    private struct ToastMessage: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    var body: some View {
        ZStack {
            Theme.Palette.partyListBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                contentArea
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            fetchedAt = Date()  // 记 fetch 基准时间供 TimelineView 递减用
            await store.loadBlocklist(reason: .initial)
        }
        .overlay(alignment: .top) {
            if let msg = toast {
                Text(msg.text)
                    // sheet 内 toast 距顶偏移比全屏 toast 缩短（sheet 顶部已有 grabber）
                    .toastStyle(topInset: 60)
                    .transition(Toast.transition)
                    .task(id: msg.id) {
                        try? await Task.sleep(nanoseconds: Toast.dismissDurationNanos)
                        toast = nil
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast?.id)
        .confirmationDialog(
            L10n.Party.blocklistRemoveConfirmTitle,
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { item in
            // Remove 按钮走全局 blocklist L10n（与 I-1 个人黑名单复用「Remove」/「Cancel」通用文案）
            Button(L10n.blocklistRemoveConfirmAction, role: .destructive) {
                Task { await performRemove(item: item) }
            }
            Button(L10n.blocklistRemoveConfirmCancel, role: .cancel) {
                pendingRemoval = nil
            }
        } message: { _ in
            Text(L10n.Party.blocklistRemoveConfirmMessage)
        }
    }

    // MARK: - Header

    private var header: some View {
        Text(L10n.Party.blocklistNavTitle)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Content area (state-driven)

    @ViewBuilder
    private var contentArea: some View {
        switch store.blocklistState {
        case .idle, .loading:
            loadingView
        case .loaded(let items), .refreshing(let items):
            // list-refresh-preserve-items rule：.refreshing 保留 items 视觉，
            // SwiftUI .refreshable 自身管顶部 spinner
            listView(items: items)
        case .empty:
            emptyView
        case .error(let msg):
            errorView(message: msg)
        }
    }

    private var loadingView: some View {
        VStack {
            ProgressView().tint(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.system(size: 42))
                .foregroundColor(.white.opacity(0.5))
            Text(L10n.Party.blocklistEmpty)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.Palette.partyGreeting)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                Task { await store.loadBlocklist(reason: .initial) }
            } label: {
                Text(L10n.Party.retry)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func listView(items: [PartyBlocklistItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(items) { item in
                    row(item: item)
                }
                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            // list-refresh-preserve-items rule B：closure 必须 await 到任务完成，spinner 才保持
            // refresh 后重置 fetchedAt —— TimelineView 用新基准算剩余秒数（后端返新 duration，本地重新递减）
            await store.refreshBlocklist()
            fetchedAt = Date()
        }
    }

    // MARK: - Row

    private func row(item: PartyBlocklistItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                avatar(url: item.avatar)
                middleInfo(item: item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                removeButton(item: item)
            }
            // 限时封禁 row 下方倒计时条（对齐 H5 blockCountdown）；永久 & duration=0 隐藏。
            // 用 TimelineView 每秒 recompute 剩余秒数 = 原 duration − (now − fetchedAt)，不需 Store 层 Timer
            if item.isTemporary && item.duration > 0 {
                TimelineView(.periodic(from: fetchedAt, by: 1)) { context in
                    let elapsed = Int(context.date.timeIntervalSince(fetchedAt).rounded(.down))
                    let remaining = max(0, item.duration - elapsed)
                    if remaining > 0 {
                        autoUnbanChip(duration: remaining)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func avatar(url: String?) -> some View {
        // 小头像走 avatarSmall（cdn-image-tier-consolidation preference）
        CachedAsyncImage(
            url: url.flatMap(URL.init(string:)),
            contentMode: .fill,
            cdn: (.avatarSmall, .fill)
        ) {
            Circle().fill(Color.white.opacity(0.1))
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    @ViewBuilder
    private func middleInfo(item: PartyBlocklistItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.nickname?.isEmpty == false ? item.nickname! : item.userId)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            // 副行：H5 展示 gender chip + age（spec §4 F1）；缺字段时 fallback 到 "ID: xxx"
            HStack(spacing: 6) {
                if let gender = item.gender, gender == 1 || gender == 2 {
                    genderChip(gender: gender, age: item.age)
                }
                if item.gender == nil, let age = item.age {
                    // 无 gender 时仅显示 age
                    Text("\(age)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.15)))
                }
                Text("ID: \(item.userId)")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.partyGreeting)
                    .lineLimit(1)
            }
        }
    }

    /// 性别 + age 一体 chip（gender=1 male 蓝底、gender=2 female 粉底；age 缺失时只显 icon）
    /// SF Symbol 保守选择（sf-symbol-usage-preflight rule）：用 person / person.fill 二态区分，
    /// 视觉上通过 tint 色（蓝/粉）承担性别语义
    private func genderChip(gender: Int, age: Int?) -> some View {
        let isMale = (gender == 1)
        return HStack(spacing: 3) {
            Image(systemName: isMale ? "person" : "person.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
            if let a = age {
                Text("\(a)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(isMale ? Color(hex: 0x4EA1FF) : Color(hex: 0xFF6A8E))
        )
    }

    private func removeButton(item: PartyBlocklistItem) -> some View {
        // secondary danger 色：透红 stroke + 淡红文字；点击 → confirmationDialog
        Button {
            pendingRemoval = item
        } label: {
            Text(L10n.blocklistRemoveConfirmAction)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(hex: 0xFF6A8E))
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(
                    Capsule().stroke(Color(hex: 0xFF6A8E).opacity(0.7), lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.blocklistAccessibilityRemoveButton)
    }

    private func autoUnbanChip(duration: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
            Text(String(format: L10n.Party.blocklistAutoUnbanFormat, formatDuration(duration)))
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(
            Capsule().stroke(Color.white.opacity(0.4), lineWidth: 1)
        )
        .padding(.leading, 52) // 与头像宽度 40 + spacing 12 对齐，视觉挂在文本行下方
    }

    /// 秒 → HH:MM:SS / MM:SS 字符串（对齐 H5 blockCountdown 直觉格式）
    private func formatDuration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, sec)
        }
        return String(format: "%02d:%02d", m, sec)
    }

    // MARK: - Actions

    private func performRemove(item: PartyBlocklistItem) async {
        pendingRemoval = nil
        do {
            try await store.removeFromBlocklist(userId: item.userId)
            toast = ToastMessage(text: L10n.Party.blocklistRemoveSuccess, isError: false)
        } catch {
            // 与 H5 差异化：H5 无差别弹成功，iOS 走 error toast（spec §0 校验 point 6）
            toast = ToastMessage(text: L10n.Party.blocklistRemoveFailed, isError: true)
        }
    }
}

/// 状态 → items 派生（sheet 内部只用两次，抽 extension 让 switch 只在 contentArea 一处；
/// 未来若 view 中需要"当前渲染 items 数"类衍生，直接读 `store.blocklistState.items`）
fileprivate extension PartyBlocklistState {
    var items: [PartyBlocklistItem] {
        switch self {
        case .loaded(let items), .refreshing(let items):
            return items
        case .idle, .loading, .empty, .error:
            return []
        }
    }
}
