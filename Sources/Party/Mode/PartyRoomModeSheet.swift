import SwiftUI

/// Party Room Mode 底部选择 sheet — 房主 tap Tools sheet 内 Room Mode 项后弹起。
///
/// **蓝本**：`livechat-h5/src/components/party/components/change-mode-popup.vue`
/// **spec**：`docs/plan/E-spec-派对房-RoomMode-MicApplication-202607141200.md` §1 + §3 + §4 A1
///
/// - Tab strip：Live+Voice(type=2) / Voice(type=1)；tap 300ms throttle 防误触
/// - LazyVGrid 2 列模板 grid；选中态紫粉渐变 stroke
/// - Level 门槛：`(createRoomLevel ?? 0) > userLevel` → toast 升级引导（不选中）
/// - 三态：idle/loading → ProgressView；loaded/partialLoaded → grid；error → 错误 + 重试
/// - Confirm button：`onConfirmRequest(selectedTempId)`；nil 时 disabled
///
/// **hoist**：本 sheet 由 PartyRoomView 单一 `activeRoomTool = .roomMode` 挂载
/// （spec §3 · swiftui-fullscreencover-hoist rule）。二次确认由父层 PartyRoomView 切换
/// 到 `.roomModeConfirm` 打开 PartyRoomModeConfirmSheet，不在本文件挂链式 sheet。
struct PartyRoomModeSheet: View {
    @ObservedObject var store: PartyStore
    /// 用户 level — 上层从 AnchorInfoStore.mine 或 SessionStore 传入用于 createRoomLevel 门槛判定
    let userLevel: Int
    /// 用户 tap Confirm 上抛 selectedTempId；父层收到后关本 sheet 并打开二次确认
    let onConfirmRequest: (Int) -> Void

    @State private var selectedType: PartyRoomModeType = .liveAndVoice
    @State private var selectedTempId: Int? = nil
    /// tab 切换 300ms throttle 时间戳（H5 `useThrottleFn(onClickTab, 300)` 对齐）
    @State private var lastTabTapAt: Date? = nil
    /// level 门槛引导 toast（overlay 展示，自动 2s 消失）
    @State private var toast: String? = nil

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ZStack(alignment: .top) {
            Theme.Palette.partyListBackground.ignoresSafeArea()
            VStack(spacing: 16) {
                Text(L10n.Party.roomModeSheetTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.top, 20)

                tabStrip

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                confirmButton
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
        }
        .presentationDetents([.medium, .large])
        .task { await store.loadRoomModeTemplates() }
        // Toast overlay（level 门槛引导；toastStyle 已包含背景 + 距顶 inset）
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
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(PartyRoomModeType.allCases, id: \.id) { type in
                tabButton(type: type)
            }
        }
        .padding(4)
        .background(Capsule().fill(Theme.Palette.partyCreateInputFill))
        .padding(.horizontal, 20)
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

    /// tab tap 300ms throttle（H5 `useThrottleFn(onClickTab, 300)` 对齐）
    private func handleTabTap(_ type: PartyRoomModeType) {
        let now = Date()
        if let last = lastTabTapAt, now.timeIntervalSince(last) < 0.3 { return }
        lastTabTapAt = now
        guard selectedType != type else { return }
        selectedType = type
        // 切 tab 重置选中：两 tab 模板不同，跨 tab 保留 selection 无视觉锚点
        selectedTempId = nil
    }

    // MARK: - Content 三态

    @ViewBuilder
    private var content: some View {
        switch store.roomModeTemplatesState {
        case .idle, .loading:
            loadingView
        case .loaded(let voice, let live):
            grid(templates: templates(voice: voice, live: live))
        case .partialLoaded(let voice, let live):
            // partialLoaded：单 tab nil 视为空 → grid 走空态分支
            grid(templates: templates(voice: voice ?? [], live: live ?? []))
        case .error:
            errorView
        }
    }

    private func templates(voice: [PartyRoomTemplate], live: [PartyRoomTemplate]) -> [PartyRoomTemplate] {
        selectedType == .voiceOnly ? voice : live
    }

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView().tint(.white)
            Spacer()
        }
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(L10n.Party.roomModeLoadError)
                .font(.system(size: 13))
                .foregroundColor(.orange)
            Button(L10n.Party.retry) {
                Task { await store.loadRoomModeTemplates() }
            }
            .foregroundColor(.white)
            Spacer()
        }
    }

    @ViewBuilder
    private func grid(templates: [PartyRoomTemplate]) -> some View {
        if templates.isEmpty {
            VStack {
                Spacer()
                Text(L10n.Party.roomModeEmptyState)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Palette.partyGreeting)
                Spacer()
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
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
        let selected = selectedTempId == temp.id
        return Button {
            handleSelect(temp)
        } label: {
            ZStack(alignment: .topTrailing) {
                templateThumbnail(temp)
                    .frame(maxWidth: .infinity)
                    // 172/156 ≈ H5 卡片比例（w-172 h-156）
                    .aspectRatio(172.0 / 156.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                if selected {
                    Image("partyTemplateSelected")
                        .resizable()
                        .frame(width: 22, height: 22)
                        .padding(6)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        selected
                        ? AnyShapeStyle(LinearGradient(
                            colors: [Theme.Palette.partyCreateBtnA, Theme.Palette.partyCreateBtnB],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color.clear),
                        lineWidth: 1.5
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 模板缩略图：优先服务端 coverImage；否则复用 PartyCreateRoomView.assetNameForTemplate 切图 fallback
    @ViewBuilder
    private func templateThumbnail(_ temp: PartyRoomTemplate) -> some View {
        if let url = temp.coverImage, !url.isEmpty, let u = URL(string: url) {
            CachedAsyncImage(url: u, persistent: true, cdn: (.avatarSmall, .fill)) {
                Rectangle().fill(Theme.Palette.partyCreateTempFill)
            }
        } else if let asset = PartyCreateRoomView.assetNameForTemplate(temp) {
            Image(asset).resizable().scaledToFit()
        } else {
            Rectangle().fill(Theme.Palette.partyCreateTempFill)
                .overlay(
                    Image(systemName: "square.grid.2x2")
                        .foregroundColor(Theme.Palette.partyCreateInputCounter)
                )
        }
    }

    private func handleSelect(_ temp: PartyRoomTemplate) {
        let required = temp.createRoomLevel ?? 0
        // H5 蓝本 `handleSelect`：createRoomLevel > userLevel 时弹升级引导，不选中
        // （iOS 未接白名单 isWithlist；F 期 UP-level 弹窗未做，本 sheet 只出 toast 提示）
        if required > userLevel {
            toast = String(format: L10n.Party.roomModeUpgradeGuideFormat, required)
            AppLogger.party.notice(
                "[PartyRoomModeSheet] level insufficient tempId=\(temp.id, privacy: .public) required=\(required, privacy: .public) userLevel=\(self.userLevel, privacy: .public)"
            )
            return
        }
        selectedTempId = temp.id
    }

    // MARK: - Confirm

    private var confirmButton: some View {
        Button {
            guard let id = selectedTempId else { return }
            onConfirmRequest(id)
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
