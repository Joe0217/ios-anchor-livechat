import SwiftUI

/// 派对房 Room Mode 模板选择通用 sheet（create + Room Mode 复用）。
///
/// **背景**：抽公共前 create 侧 `PartyCreateModePickerSheet` 与房间内
/// `PartyRoomModeSheet` 各写一份，同款 UI 陷阱在一处修好另一处遗漏，用户反馈
/// "两处 UI 不一致"。本组件收敛：card 用 create v7.13 pattern（有底色 partyCreateTempFill
/// + fixed height 140 + padding + 单色 stroke），tab strip 用 Room Mode 的 gradient +
/// 300ms throttle + PartyRoomModeType 枚举。
///
/// **交互**：
/// - Tab 切换：本地 @State selectedType；`onTabChange` 回调让父层同步 Store（如 create
///   `store.selectMode(type.rawValue)` 触发补拉）
/// - Card tap：`enforceLevelGate=true` 时 `createRoomLevel > userLevel` 弹 toast 不选中；
///   否则本地 selectedTempId 更新
/// - Confirm：`onConfirm(tempId, type)` 上抛，父层负责关闭 + 后续动作（create 侧写
///   store.selectedTemplate；Room Mode 侧弹二次确认）
///
/// **数据源**：`voiceTemplates` + `liveTemplates` 由父层从 store 拆分传入（create 侧从
/// `templatesByMode[1/2]`；Room Mode 侧从 `roomModeTemplatesState` 拆 voice/live 两个数组）。
/// 组件不订阅 store，纯 UI + 本地 @State。
struct PartyRoomTemplatePickerSheet: View {
    // MARK: - 数据

    let voiceTemplates: [PartyRoomTemplate]
    let liveTemplates: [PartyRoomTemplate]
    /// 107 Party-only 账号只允许语音模板。默认保留既有两种房型，避免影响普通账号。
    let availableTypes: [PartyRoomModeType]
    let isLoading: Bool
    let errorMessage: String?
    let onRetry: (() -> Void)?

    // MARK: - 初始选中

    let initialType: PartyRoomModeType
    let initialSelectedTempId: Int?

    // MARK: - Level gate（Room Mode 有门槛 / Create v6 无门槛对齐安卓）

    let userLevel: Int
    let enforceLevelGate: Bool

    // MARK: - 空态文案（create/Room Mode 分开 L10n key 传入）

    let emptyText: String

    // MARK: - Callbacks

    let onTabChange: ((PartyRoomModeType) -> Void)?
    let onConfirm: (Int, PartyRoomModeType) -> Void

    // MARK: - 本地 @State

    @State private var selectedType: PartyRoomModeType
    @State private var selectedTempId: Int?
    /// tab 切换 300ms throttle（H5 `useThrottleFn(onClickTab, 300)`）
    @State private var lastTabTapAt: Date? = nil
    /// level 门槛引导 toast（2s 自动消失）
    @State private var toast: String? = nil

    init(
        voiceTemplates: [PartyRoomTemplate],
        liveTemplates: [PartyRoomTemplate],
        availableTypes: [PartyRoomModeType] = PartyRoomModeType.allCases,
        isLoading: Bool,
        errorMessage: String?,
        onRetry: (() -> Void)? = nil,
        initialType: PartyRoomModeType,
        initialSelectedTempId: Int?,
        userLevel: Int = 0,
        enforceLevelGate: Bool = false,
        emptyText: String,
        onTabChange: ((PartyRoomModeType) -> Void)? = nil,
        onConfirm: @escaping (Int, PartyRoomModeType) -> Void
    ) {
        self.voiceTemplates = voiceTemplates
        self.liveTemplates = liveTemplates
        let resolvedTypes = availableTypes.isEmpty ? [.voiceOnly] : availableTypes
        self.availableTypes = resolvedTypes
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.onRetry = onRetry
        let resolvedInitialType = resolvedTypes.contains(initialType)
            ? initialType
            : (resolvedTypes.first ?? .voiceOnly)
        self.initialType = resolvedInitialType
        self.initialSelectedTempId = initialSelectedTempId
        self.userLevel = userLevel
        self.enforceLevelGate = enforceLevelGate
        self.emptyText = emptyText
        self.onTabChange = onTabChange
        self.onConfirm = onConfirm
        _selectedType = State(initialValue: resolvedInitialType)
        _selectedTempId = State(initialValue: initialSelectedTempId)
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 16) {
                Text(L10n.Party.roomModeSheetTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.top, 20)

                tabStrip

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            confirmButton
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .overlay(alignment: .top) {
            if let msg = toast {
                Text(msg)
                    .toastStyle()
                    .transition(Toast.transition)
                    .task(id: msg) {
                        try? await Task.sleep(nanoseconds: Toast.dismissDurationNanos)
                        toast = nil
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
        .onChange(of: availableTypes) { types in
            guard !types.contains(selectedType) else { return }
            let fallback = types.first ?? .voiceOnly
            selectedType = fallback
            selectedTempId = nil
            onTabChange?(fallback)
        }
    }

    // MARK: - Tab strip（Room Mode 版：gradient + throttle + enum）

    @ViewBuilder
    private var tabStrip: some View {
        if availableTypes.count > 1 {
            HStack(spacing: 0) {
                ForEach(availableTypes, id: \.id) { type in
                    tabButton(type: type)
                }
            }
            .padding(4)
            .background(Capsule().fill(Theme.Palette.partyCreateInputFill))
            .padding(.horizontal, 20)
        }
    }

    private func tabButton(type: PartyRoomModeType) -> some View {
        let active = selectedType == type
        return Button {
            handleTabTap(type)
        } label: {
            Text(type.tabTitle)
                .font(.system(size: 14, weight: active ? .semibold : .medium))
                .foregroundColor(active ? .white : Theme.Palette.partyCreateModeTabInactive)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(
                        active
                        ? AnyShapeStyle(LinearGradient(
                            colors: [
                                Theme.Palette.partyCreateModeTabA,
                                Theme.Palette.partyCreateModeTabB,
                                Theme.Palette.partyCreateModeTabC,
                            ],
                            startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Color.clear)
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func handleTabTap(_ type: PartyRoomModeType) {
        guard availableTypes.contains(type) else { return }
        let now = Date()
        if let last = lastTabTapAt, now.timeIntervalSince(last) < 0.3 { return }
        lastTabTapAt = now
        guard selectedType != type else { return }
        selectedType = type
        // 切 tab 重置选中：两 tab 模板不同，跨 tab 保留 selection 无视觉锚点
        selectedTempId = nil
        onTabChange?(type)
    }

    // MARK: - Content 三态

    @ViewBuilder
    private var content: some View {
        if isLoading {
            loadingView
        } else if let msg = errorMessage, !msg.isEmpty {
            errorView(msg)
        } else {
            grid(templates: currentTemplates)
        }
    }

    private var currentTemplates: [PartyRoomTemplate] {
        selectedType == .voiceOnly ? voiceTemplates : liveTemplates
    }

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView().tint(.white)
            Spacer()
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Text(msg)
                .font(.system(size: 13))
                .foregroundColor(.orange)
            if let retry = onRetry {
                Button(L10n.Party.retry, action: retry)
                    .foregroundColor(.white)
            }
            Spacer()
        }
    }

    // MARK: - Grid（create v7.13 card pattern）

    @ViewBuilder
    private func grid(templates: [PartyRoomTemplate]) -> some View {
        if templates.isEmpty {
            VStack {
                Spacer()
                Text(emptyText)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Palette.partyGreeting)
                Spacer()
            }
        } else {
            ScrollView {
                // LazyVGrid 垂直 spacing + 每列 GridItem spacing 都要设水平/垂直间距才对称
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)],
                    spacing: 20
                ) {
                    ForEach(templates, id: \.id) { temp in
                        templateCard(temp)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func templateCard(_ temp: PartyRoomTemplate) -> some View {
        // 对齐 create v7.13 pattern：三层 fallback（coverImage URL → asset name → SF Symbol placeholder）
        // + 固定 height 140（aspectRatio(.fit) 在 LazyVGrid flex column 里高度会崩塌到 0）
        // + 底色 partyCreateTempFill + 8pt padding + 单色 stroke
        let selected = selectedTempId == temp.id
        return Button {
            handleSelect(temp)
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let cover = temp.coverImage, !cover.isEmpty, let u = URL(string: cover) {
                        CachedAsyncImage(url: u, contentMode: .fill, cdn: (.avatarLarge, .fill)) {
                            Rectangle().fill(Theme.Palette.partyCreateTempFill)
                        }
                    } else if let asset = temp.fallbackAssetName {
                        Image(asset).resizable().scaledToFill()
                    } else {
                        Image(systemName: "square.grid.2x2")
                            .resizable().scaledToFit()
                            .foregroundColor(Theme.Palette.partyCreateInputCounter)
                            .padding(20)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if selected {
                    Image("partyTemplateSelected")
                        .resizable()
                        .frame(width: 22, height: 22)
                        .padding(6)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.Palette.partyCreateTempFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Theme.Palette.partyCreateTempSelected : Color.clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func handleSelect(_ temp: PartyRoomTemplate) {
        if enforceLevelGate {
            let required = temp.createRoomLevel ?? 0
            if required > userLevel {
                toast = String(format: L10n.Party.roomModeUpgradeGuideFormat, required)
                AppLogger.party.notice(
                    "[TemplatePicker] level insufficient tempId=\(temp.id, privacy: .public) required=\(required, privacy: .public) userLevel=\(self.userLevel, privacy: .public)"
                )
                return
            }
        }
        selectedTempId = temp.id
    }

    // MARK: - Confirm

    private var confirmButton: some View {
        Button {
            guard let id = selectedTempId else { return }
            onConfirm(id, selectedType)
        } label: {
            HStack {
                Spacer()
                Text(L10n.Party.createConfirm)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.vertical, 14)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [Theme.Palette.partyCreateBtnA, Theme.Palette.partyCreateBtnB],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(selectedTempId == nil)
        .opacity(selectedTempId == nil ? 0.5 : 1)
    }
}
