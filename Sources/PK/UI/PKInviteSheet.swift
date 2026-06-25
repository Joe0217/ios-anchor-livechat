import SwiftUI

/// G 里程碑 spec §6 / M3-3 + 2026-06-25 §1.2 反悔扩展：发起 PK 邀请 sheet。
///
/// 接 H5 蓝本 `pkInitiatePopup.vue` 的核心区块：
/// - 顶部：接受邀请开关（`acceptInviteSwitchOn`）
/// - 中部：搜索栏（纯数字→anchorId / 文本→nickname）+ pkDuration 4 档选择
/// - 主体：推荐列表（无限滚动）/ 搜索结果列表
/// - 列表项：5 态按钮（自己 / 已邀请 / 0 忙 / 2 等待 / 3 PKing / 1 可邀）
/// - 历史/规则/时长设置弹窗：G 范围外，留 backlog
struct PKInviteSheet: View {
    @ObservedObject var store: PKStore
    @Binding var isPresented: Bool

    @State private var duration: Int = 300
    @State private var inputKeyword: String = ""

    private let durations: [(value: Int, label: String)] = [
        (180, L10n.PK.inviteDuration3),
        (300, L10n.PK.inviteDuration5),
        (600, L10n.PK.inviteDuration10),
        (900, L10n.PK.inviteDuration15),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topSection
                Divider().background(Color.white.opacity(0.1))
                listSection
            }
            .background(LinearGradient(colors: [Color(red: 0.21, green: 0.12, blue: 0.62),
                                                Color(red: 0.09, green: 0.02, blue: 0.24)],
                                       startPoint: .top, endPoint: .bottom))
            .navigationTitle(L10n.PK.inviteTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.PK.matchingCancel) { isPresented = false }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .presentationDetents([.large])
        .task {
            await store.loadInviteSwitchIfNeeded()
            await store.refreshRecommendList()
        }
    }

    // MARK: - 顶部：接受邀请开关 + 时长 + 搜索栏

    private var topSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.PK.inviteAcceptSwitch)
                    .foregroundStyle(.white)
                    .font(.subheadline)
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
                .tint(.pink)
            }

            Picker(L10n.PK.inviteDurationLabel, selection: $duration) {
                ForEach(durations, id: \.value) { item in
                    Text(item.label).tag(item.value)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.6))
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
                }
                Button(action: triggerSearch) {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(.pink)
                        .font(.title3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
        }
        .padding(16)
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
                                        onTap: { handleButtonTap(for: anchor) })
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
                                  enabled: false,
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
        // 已邀请 → 暂不展开 waiting 弹窗（spec backlog；只是无操作）
        if store.invitedAnchors[anchor.userId] != nil {
            return
        }
        // 后端禁态 toast 由 disabled 阻挡，不发起
        guard store.invitedAnchors.count < 5 else { return }
        Task {
            await store.inviteByAnchorId(anchor.userId,
                                          duration: duration,
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

    var body: some View {
        HStack(spacing: 12) {
            avatar
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

    private var avatar: some View {
        AsyncImage(url: URL(string: anchor.displayAvatar ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            default: Color.white.opacity(0.15)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
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
