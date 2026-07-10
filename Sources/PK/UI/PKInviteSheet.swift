import SwiftUI

/// G 里程碑 spec §6 / M3-3 + 2026-07-11 深度对齐 H5：发起 PK 邀请 sheet。
///
/// **对齐 H5 `pkInitiatePopup.vue` 完整结构**（自上而下）：
/// - **自定义 header row**：左标题 "Initiate PK" + `?` rule icon；右 history icon + setting icon
/// - **PKMatchingCard**：随机匹配 embed 卡（idle/matching/matched 三态；见 [PKMatchingCard]）
/// - **Accept PK invitation switch row**：`acceptInviteSwitchOn` 双向绑定
/// - **Search field**：clearable + submit（纯数字→anchorId / 文本→nickname）
/// - **List area**：推荐/搜索结果分页 + 5 态按钮 anchor row
///
/// **交互对齐 H5**：
/// - Header `?` tap → `showRule=true` 打开 `PKRulePopup`（用 `.fullScreenCover` 挂在本 sheet 内部
///   保证层级盖过 sheet + 透明背景实现"屏幕中央居中卡片"视觉，参 [swiftui-fullscreencover-hoist]）；
///   首次自动打开（`ruleFirstTimeShown` @AppStorage 记录）
/// - Header history tap → `showHistory=true` 打开 `PKHistoryPopup`
/// - Header setting tap → `showDurationPicker=true` 打开 `PKDurationPickerSheet`（4 选项 3/5/10/15 min）
/// - anchor avatar tap → `onTapAvatar(userId)` callback 上抛（LiveRoomView 设 `userCardUserId`）
/// - anchor row "Waiting" 按钮 tap → 关闭本 sheet 露出底层 `PKInviteWaitingPopup`
/// - `.inviting` 起任何 non-idle/failed state → `handlePKStateChange` 自动关闭本 sheet
///
/// **iOS 简化**（不严格对齐 H5 的装饰）：
/// - Rule popup 10s 强制阅读：iOS 首次自动打开，允许用户随时关闭（HIG 惯例，避免"强制阅读"审核风险）
/// - PkAvatarCarousel 轮播头像 → 静态 `?` 占位（PKMatchingCard 内简化）
/// - SVGA 15s 倒计时动画 → 系统 ProgressView 圆形 spinner
struct PKInviteSheet: View {
    @ObservedObject var store: PKStore
    @Binding var isPresented: Bool
    /// tap anchor avatar 上抛的 userId（LiveRoomView 用于设 `userCardUserId` 打开 UserCardPopup）
    let onTapAvatar: (String) -> Void
    /// 我方 anchor 头像 URL（PKMatchingCard idle 左侧头像用；LiveRoomView 从 AnchorInfoStore 派生传入）
    let selfAvatarURL: String?
    @State private var inputKeyword: String = ""

    // sub-sheet / popup 显隐
    /// Rule popup 用 `.fullScreenCover` 挂在本 sheet 内保证层级盖过 sheet；内容透明背景 + 中央卡片模拟"居中弹窗"视觉
    @State private var showRule: Bool = false
    @State private var showHistory: Bool = false
    @State private var showDurationPicker: Bool = false

    /// 首次打开邀请 sheet 时自动弹 rule popup 一次（对齐 H5 localStorage `pk_rule_first_time_shown`）
    @AppStorage("pk_rule_first_time_shown") private var ruleFirstTimeShown: Bool = false

    /// 显式 internal init：多个 `@State private` / `@AppStorage private` 会让编译器把 memberwise init 降级为 private，
    /// 外部（LiveRoomView）无法访问 → 显式提供 init 绕开
    init(store: PKStore,
         isPresented: Binding<Bool>,
         onTapAvatar: @escaping (String) -> Void,
         selfAvatarURL: String?) {
        self.store = store
        self._isPresented = isPresented
        self.onTapAvatar = onTapAvatar
        self.selfAvatarURL = selfAvatarURL
    }

    var body: some View {
        // 对齐 H5 pkInitiatePopup.vue L388-505：**固定顶部 + 底部 List 独占滚动**。
        // iOS 上一轮把顶部包 ScrollView + maxHeight:320 → 内容溢出时搜索框被裁掉遮挡。改为顶部 fixed 布局
        VStack(spacing: 0) {
            headerBar
            VStack(spacing: 0) {
                PKMatchingCard(store: store,
                               selfAvatarURL: selfAvatarURL,
                               onStartMatch: handleStartRandomMatch,
                               onCancelMatch: handleCancelMatch)
                acceptSwitchRow
                searchField
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            Divider().background(Color.white.opacity(0.1))
            listSection
        }
        .background(
            LinearGradient(colors: [Color(hex: 0x371F9F),
                                    Color(hex: 0x17063D)],
                           startPoint: .top, endPoint: .bottom)
        )
        // 键盘弹起时 SwiftUI 默认缩减 safe area 会把 List 上推 → 遮住上方 search field。
        // 忽略键盘 safe area 保持整 sheet 布局固定（键盘覆盖底部 List 的一部分即可，不推整体上移）
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .task {
            await store.loadInviteSwitchIfNeeded()
            await store.refreshRecommendList()
            // 首次自动打开 rule popup（对齐 H5 pkInitiatePopup.vue:311-326 首次强制阅读）
            if !ruleFirstTimeShown {
                showRule = true
                ruleFirstTimeShown = true
            }
        }
        .overlay { historyPopupOverlay }
        // Rule popup 用 fullScreenCover 挂在本 sheet 内部：SwiftUI fullScreenCover 会**盖过** sheet 层级；
        // 内容 view 内加 ClearBackgroundHelper 让 fullScreenCover 背景透明，露出半透黑蒙层 + 中央卡片视觉
        .fullScreenCover(isPresented: $showRule) {
            PKRulePopup(isPresented: $showRule)
        }
        .sheet(isPresented: $showDurationPicker) {
            PKDurationPickerSheet(store: store, isPresented: $showDurationPicker)
                .presentationDetents([.fraction(0.4)])
        }
    }

    // MARK: - Header row（对齐 H5 pkInitiatePopup.vue L390-407）

    private var headerBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.PK.initiateTitle)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                Button {
                    showRule = true
                } label: {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.PK.ruleTitle))
            }

            Spacer()

            HStack(spacing: 16) {
                Button {
                    showHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.PK.historyTitle))

                Button {
                    showDurationPicker = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.PK.durationPickerTitle))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    // MARK: - Accept switch row（对齐 H5 pkInitiatePopup.vue L417-421）

    private var acceptSwitchRow: some View {
        HStack {
            Text(L10n.PK.inviteAcceptSwitch)
                .foregroundStyle(.white)
                .font(.system(size: 15))
            Spacer()
            if store.inviteSwitchLoading {
                ProgressView().tint(.white).scaleEffect(0.8)
            }
            Toggle("", isOn: Binding(
                get: { store.acceptInviteSwitchOn },
                set: { newValue in
                    Task { await store.setInviteSwitch(accept: newValue) }
                }
            ))
            .labelsHidden()
            .tint(Color(hex: 0xFF1AA7))
        }
        .padding(.bottom, 20)
    }

    // MARK: - Search field（对齐 H5 pkInitiatePopup.vue L423-441）

    private var searchField: some View {
        HStack(spacing: 8) {
            TextField("", text: $inputKeyword, prompt: Text(L10n.PK.inviteSearchPlaceholder)
                .foregroundColor(.white.opacity(0.4)))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
                .submitLabel(.search)
                .onSubmit { triggerSearch() }
            if !inputKeyword.isEmpty {
                Button {
                    inputKeyword = ""
                    Task { await store.clearSearch() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            Button(action: triggerSearch) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.8))
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.white.opacity(0.1), in: Capsule())
        .overlay(Capsule().stroke(Color(hex: 0x412393), lineWidth: 1))
        .padding(.bottom, 12)
    }

    // MARK: - History overlay（rule popup 已 hoist 到 LiveRoomView 层做屏幕居中）

    @ViewBuilder
    private var historyPopupOverlay: some View {
        if showHistory {
            PKHistoryPopup(isPresented: $showHistory)
        }
    }

    // MARK: - Match card handlers

    private func handleStartRandomMatch() {
        Task { await store.startRandomMatch() }
    }

    private func handleCancelMatch() {
        Task { await store.cancelMatch() }
    }

    // MARK: - 主体：列表

    private var listSection: some View {
        Group {
            if store.recommendList.isEmpty && !store.recommendLoading {
                emptyView
            } else {
                List {
                    Section(header:
                        Text(store.isSearching ? L10n.PK.inviteSearchResultTitle : L10n.PK.inviteRecommendTitle)
                            .foregroundStyle(.white.opacity(0.7))
                    ) {
                        ForEach(store.recommendList) { anchor in
                            PKAnchorRow(anchor: anchor,
                                        config: buttonConfig(for: anchor),
                                        onTap: { handleButtonTap(for: anchor) },
                                        onAvatarTap: { onTapAvatar(String(anchor.userId)) })
                                .listRowBackground(Color.white.opacity(0.05))
                                .listRowSeparatorTint(.white.opacity(0.1))
                                .onAppear {
                                    if anchor.userId == store.recommendList.last?.userId,
                                       store.recommendHasMore, !store.recommendLoading {
                                        Task { await store.loadMoreRecommend() }
                                    }
                                }
                        }
                        if store.recommendLoading {
                            HStack {
                                Spacer()
                                ProgressView().tint(.white)
                                Spacer()
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var emptyView: some View {
        VStack {
            Spacer()
            if store.recommendLoading {
                ProgressView().tint(.white)
            } else {
                Text(L10n.PK.inviteEmpty)
                    .foregroundStyle(.white.opacity(0.5))
                    .font(.subheadline)
            }
            Spacer()
        }
    }

    // MARK: - 按钮态 + 行为（H5 usePkInviteButton.getButtonConfig 5 态）

    private func buttonConfig(for anchor: PKRecommendAnchor) -> PKButtonConfig {
        // 1. 已邀请（本端字典命中）
        if store.invitedAnchors[anchor.userId] != nil {
            return PKButtonConfig(title: L10n.PK.inviteBtnWaiting,
                                  enabled: true,   // 2026-07-11：改 true 允许 tap 打开 waiting popup
                                  style: .waiting)
        }
        // 2. 后端 pkStatus 0/2/3 → 禁用 + toast
        switch anchor.pkStatus {
        case 0?: return PKButtonConfig(title: L10n.PK.inviteBtnInvite,
                                       enabled: false,
                                       style: .disabled)
        case 2?: return PKButtonConfig(title: L10n.PK.inviteBtnInvite,
                                       enabled: false,
                                       style: .disabledLight)
        case 3?: return PKButtonConfig(title: L10n.PK.inviteBtnPKing,
                                       enabled: false,
                                       style: .pking)
        default:
            // 3. 可邀（pkStatus=1 / nil）
            return PKButtonConfig(title: L10n.PK.inviteBtnInvite,
                                  enabled: true,
                                  style: .invite)
        }
    }

    private func handleButtonTap(for anchor: PKRecommendAnchor) {
        // 匹配中不允许邀请（H5 line 87-90 同行为）
        if store.state == .matching {
            return
        }
        // 已邀请 → 对齐 H5 pkInitiatePopup.vue tap Waiting 打开等待弹窗：
        // iOS `.inviting` state 时 handlePKStateChange 已自动 set showPKInviteWaiting=true，
        // waiting popup 处在 pkPopupsOverlay 但被 InviteSheet 遮挡；关闭 InviteSheet 让底层 waiting popup 露出
        if store.invitedAnchors[anchor.userId] != nil {
            isPresented = false
            return
        }
        // 后端禁态 toast 由 disabled 阻挡，不发起
        guard store.invitedAnchors.count < 5 else { return }
        Task {
            await store.inviteByAnchorId(anchor.userId,
                                          duration: store.defaultDuration,
                                          nickname: anchor.nickname,
                                          avatar: anchor.displayAvatar)
        }
    }

    private func triggerSearch() {
        store.setSearchKeyword(inputKeyword)
        Task { await store.performSearch() }
    }
}

// MARK: - 列表项

private struct PKAnchorRow: View {
    let anchor: PKRecommendAnchor
    let config: PKButtonConfig
    let onTap: () -> Void
    let onAvatarTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onAvatarTap) {
                AvatarView(urlString: anchor.displayAvatar, size: 40, kind: .anchor)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(anchor.nickname ?? ""))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(anchor.nickname ?? "—")
                        .foregroundStyle(.white)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let country = anchor.countryId, !country.isEmpty {
                        Text(country)
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.white.opacity(0.1), in: Capsule())
                    }
                }
                Text("ID: \(anchor.userId)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button(action: onTap) {
                Text(config.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(config.style.foreground)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(config.style.background, in: Capsule())
            }
            .disabled(!config.enabled)
            .opacity(config.enabled ? 1 : 0.85)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - 按钮配置 model

private struct PKButtonConfig {
    let title: String
    let enabled: Bool
    let style: Style

    enum Style {
        case invite, waiting, pking, disabled, disabledLight

        var foreground: Color {
            switch self {
            case .invite, .waiting, .pking, .disabled: return .white
            case .disabledLight: return .white.opacity(0.6)
            }
        }
        var background: AnyShapeStyle {
            switch self {
            case .invite:
                return AnyShapeStyle(LinearGradient(colors: [.green, Color(red: 0, green: 0.56, blue: 0.07)],
                                                    startPoint: .top, endPoint: .bottom))
            case .waiting:
                return AnyShapeStyle(LinearGradient(colors: [Color.orange, Color(red: 0.91, green: 0.18, blue: 0)],
                                                    startPoint: .top, endPoint: .bottom))
            case .pking:
                return AnyShapeStyle(LinearGradient(colors: [Color(red: 0.54, green: 0, blue: 0.92),
                                                              Color(red: 0.36, green: 0, blue: 0.99)],
                                                    startPoint: .top, endPoint: .bottom))
            case .disabled:
                return AnyShapeStyle(LinearGradient(colors: [Color(red: 0.72, green: 0.75, blue: 0.79),
                                                              Color(red: 0.35, green: 0.41, blue: 0.47)],
                                                    startPoint: .top, endPoint: .bottom))
            case .disabledLight:
                return AnyShapeStyle(Color.white.opacity(0.2))
            }
        }
    }
}
