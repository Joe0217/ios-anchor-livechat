import SwiftUI

/// Party Room Mode 底部选择 sheet — 房主 tap Tools sheet 内 Room Mode 项后弹起。
///
/// **蓝本**：`livechat-h5/src/components/party/components/change-mode-popup.vue`
/// **spec**：`docs/plan/E-spec-派对房-RoomMode-MicApplication-202607141200.md` §1 + §3 + §4 A1
///
/// v7.14 起 UI 抽到 [PartyRoomTemplatePickerSheet](../UI/Components/PartyRoomTemplatePickerSheet.swift)
/// 通用组件，与创房页 PartyCreateModePickerSheet 复用同款 card + tab strip。
/// 本 wrapper 只做房间内 PartyStore 数据桥接 + Confirm 回调转发。
///
/// **数据桥**：从 `store.roomModeTemplatesState` 拆 voice/live 两组模板。
/// - `.idle` / `.loading` → isLoading=true
/// - `.loaded(voice, live)` → 两组直接给
/// - `.partialLoaded(voice, live)` → 单 tab nil 视为空数组（用户切过去看空态）
/// - `.error` → errorMessage 传入
///
/// **hoist**：本 sheet 由 PartyRoomView 单一 `activeRoomTool = .roomMode` 挂载
/// （spec §3 · swiftui-fullscreencover-hoist rule）。二次确认由父层 PartyRoomView 切换
/// 到 `.roomModeConfirm` 打开 PartyRoomModeConfirmSheet，不在本文件挂链式 sheet。
struct PartyRoomModeSheet: View {
    @ObservedObject var store: PartyStore
    @ObservedObject private var permission = SelfPermissionBridge.shared
    /// 用户 tap Confirm 上抛 selectedTempId；父层收到后关本 sheet 并打开二次确认
    let onConfirmRequest: (Int) -> Void

    var body: some View {
        NavigationStack {
            PartyRoomTemplatePickerSheet(
                voiceTemplates: voiceTemplates,
                liveTemplates: liveTemplates,
                availableTypes: availableTemplateTypes,
                isLoading: isLoading,
                errorMessage: errorMessage,
                onRetry: { Task { await store.loadRoomModeTemplates() } },
                initialType: initialType,
                initialSelectedTempId: nil,       // Room Mode 无预选：让用户主动选后再 Confirm
                enforceLevelGate: false,          // 用户明示：对齐 create v6 无等级门槛（2026-07-16）
                emptyText: L10n.Party.roomModeEmptyState,
                onConfirm: { tempId, type in
                    guard availableTemplateTypes.contains(type) else { return }
                    onConfirmRequest(tempId)
                }
            )
        }
        // 模板选择页默认占屏 60%，与确认弹窗的内容自适应高度分开。
        .presentationDetents([.fraction(0.6)])
        .task { await store.loadRoomModeTemplates() }
        .onChange(of: permission.canPartyVideo) { _ in
            // Store 会清掉 live cache；picker 自身会根据 availableTypes 收敛当前 tab。
            Task { await store.loadRoomModeTemplates() }
        }
    }

    // MARK: - 数据桥（PartyStore.roomModeTemplatesState → voice/live 两数组 + isLoading + error）

    private var voiceTemplates: [PartyRoomTemplate] {
        switch store.roomModeTemplatesState {
        case .loaded(let v, _): return v
        case .partialLoaded(let v, _): return v ?? []
        default: return []
        }
    }

    private var liveTemplates: [PartyRoomTemplate] {
        guard permission.canPartyVideo else { return [] }
        switch store.roomModeTemplatesState {
        case .loaded(_, let l): return l
        case .partialLoaded(_, let l): return l ?? []
        default: return []
        }
    }

    private var isLoading: Bool {
        switch store.roomModeTemplatesState {
        case .idle, .loading: return true
        default: return false
        }
    }

    private var errorMessage: String? {
        if case .error(let msg) = store.roomModeTemplatesState { return msg }
        return nil
    }

    /// 默认打开 Live+Voice tab（与原 PartyRoomModeSheet 初始态一致）；107 固定语音。
    private var initialType: PartyRoomModeType {
        permission.canPartyVideo ? .liveAndVoice : .voiceOnly
    }

    private var availableTemplateTypes: [PartyRoomModeType] {
        permission.canPartyVideo ? PartyRoomModeType.allCases : [.voiceOnly]
    }

}
