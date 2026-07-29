import SwiftUI

/// 派对房公屏消息列表（v3 2026-07-15 迁移到 unified `PublicChatRow`）。
///
/// **架构**：数据源 `chat.messages: [UnifiedPublicChatMessage]`，UI 层通过 `PublicChatRow` 分派
/// 各 variant Row 组件（与直播场景零重复）；翻译交互沿用 `PublicChatListView` 相同模式。
///
/// **拆出原因**（review 202606252033 P1-6）：
/// - `chat.messages` 高频变化（活跃房 >5 条/秒），每次都触发整个 PartyRoomView body 重算
/// - 顶层 body 重算 → seatGrid + LazyVGrid 重新 evaluate → PartyRemoteVideoView / CameraPreview 抖动
/// - 抽到独立子 view 后，@ObservedObject chat 仅触发本子 view 重 evaluate；麦位区完全不受影响
///
/// **入参**：
/// - `chat`: 观测 messages + 历史拉取状态
/// - `filter`: All/Chat/Gift 三档过滤（对齐 H5 + Android 派对房蓝本）
/// - `lastGiftEvent`: v3 前的"最近一条送礼 banner"—— **v3 起 gift 消息直接进 feed（`.gift` variant）**，
///   此参数保留传参但不再渲染（未来彻底移除）
struct PartyMessageListView: View {
    @ObservedObject var chat: PartyRoomChatManager
    /// tab 过滤：`.all` 全部 / `.chat` 排除 gift/luckyGift/gameWinNotify/winnerBroadcast / `.gift` 仅 gift + luckyGift
    var filter: PartyRoomChatFilter = .all
    /// v3 前置字段，暂保留兼容 caller；v3 后 gift 已进 feed 无需 banner，不再渲染
    let lastGiftEvent: PartyGiftEvent?
    /// 防重入 map:正在翻译中的 msgId
    @State private var pendingTranslateIds: Set<UUID> = []
    @State private var deleteActionMessage: UnifiedPublicChatMessage?
    @State private var deleteConfirmationMessage: UnifiedPublicChatMessage?
    @State private var deletingMessageId: UUID?
    @State private var deleteToast: String?
    @Environment(\.avatarUserCardPresenter) private var userCardPresenter

    /// 房主/房管/平台管理员可删除文本消息；调用方在 PartyRoomView 统一按当前角色授权。
    var canDeleteTextMessages: Bool = false
    var onDeleteTextMessage: ((UnifiedPublicChatMessage) async -> Bool)? = nil
    /// 活动中奖广播点击；PartyRoomView 以半屏活动页承载。
    var onWinnerActivity: ((String) -> Void)? = nil

    /// 过滤后的消息列表（对齐 H5/Android tab 过滤语义 + unified variant discriminator）
    private var filteredMessages: [UnifiedPublicChatMessage] {
        switch filter {
        case .all:
            return chat.messages
        case .chat:
            return chat.messages.filter { !isGiftLikeVariant($0.variant) }
        case .gift:
            return chat.messages.filter { isGiftLikeVariant($0.variant) }
        }
    }

    /// 判定"礼物类"消息（gift + luckyGift 归 Gift tab；其他系统广播归 Chat tab）。
    private func isGiftLikeVariant(_ variant: PublicChatVariant) -> Bool {
        switch variant {
        case .gift, .luckyGift, .firstGiftMoment: return true
        default: return false
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(filteredMessages) { msg in
                        PublicChatRow(
                            message: msg,
                            theme: .party,
                            onTapTranslate: { m in handleTapTranslate(msg: m) },
                            isTranslating: pendingTranslateIds.contains(msg.id),
                            onTapUserCard: userCardPresenter,
                            onWinnerActivity: onWinnerActivity
                        )
                        .id(msg.id)
                        .onLongPressGesture(minimumDuration: 0.5) {
                            presentDeleteAction(for: msg)
                        }
                    }
                }
                .padding(.vertical, 8)
                // 水平 padding 由外层 PartyRoomChatArea `Theme.Metric.partyRoomChatHPadding` 统一控制，
                // 与 PartyRoomChatTabStrip 的 `partyRoomScreenH` 同值 → 消息内容左边与 All tab 文字对齐
            }
            .onChange(of: chat.messages.count) { _ in
                if let last = filteredMessages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .confirmationDialog(
            L10n.Party.deleteMessage,
            isPresented: Binding(
                get: { deleteActionMessage != nil },
                set: { if !$0 { deleteActionMessage = nil } }
            ),
            presenting: deleteActionMessage
        ) { message in
            Button(L10n.Party.deleteMessage, role: .destructive) {
                deleteConfirmationMessage = message
            }
            Button(L10n.Party.cancel, role: .cancel) {}
        }
        .alert(
            L10n.Party.deleteMessageConfirm,
            isPresented: Binding(
                get: { deleteConfirmationMessage != nil },
                set: { if !$0 { deleteConfirmationMessage = nil } }
            )
        ) {
            Button(L10n.Party.cancel, role: .cancel) {
                deleteConfirmationMessage = nil
            }
            Button(L10n.Party.deleteMessage, role: .destructive) {
                guard let message = deleteConfirmationMessage else { return }
                deleteConfirmationMessage = nil
                deleteMessage(message)
            }
        }
        .overlay(alignment: .top) {
            if let deleteToast {
                Text(deleteToast)
                    .toastStyle()
                    .transition(Toast.transition)
                    .task(id: deleteToast) {
                        try? await Task.sleep(nanoseconds: Toast.dismissDurationNanos)
                        self.deleteToast = nil
                    }
            }
        }
        // 聊天区盖在 room 背景大图上，systemBackground（dark 下不透明黑）会抹掉底图；
        // 改用 clear 让底图透出。
    }

    // MARK: - 翻译 tap 处理（防重入 + 调 MicrosoftTranslateService + chat.setTranslation）

    private func handleTapTranslate(msg: UnifiedPublicChatMessage) {
        // 仅 .text variant 可翻译
        guard case .text(let content, _, let existing, _) = msg.variant,
              existing == nil,
              !content.isEmpty,
              !pendingTranslateIds.contains(msg.id) else { return }
        pendingTranslateIds.insert(msg.id)
        guard let key = AppConfigStore.shared.microsoftTranslatorKey,
              let area = AppConfigStore.shared.microsoftTranslatorArea else {
            pendingTranslateIds.remove(msg.id)
            AppLogger.party.warning("[PartyChat] translate unavailable: config missing")
            return
        }
        let targetLang: String = {
            switch AppLocaleStore.shared.current {
            case .en: return "en"
            case .ar: return "ar"
            case .tr: return "tr"
            case .system: return Locale.current.language.languageCode?.identifier ?? "en"
            }
        }()
        Task { @MainActor in
            defer { pendingTranslateIds.remove(msg.id) }
            do {
                let translated = try await MicrosoftTranslateService.shared.translate(
                    text: content, targetLang: targetLang, key: key, area: area
                )
                chat.setTranslation(messageId: msg.id, translation: translated)
            } catch {
                AppLogger.party.warning("[PartyChat] translate failed msgId=\(msg.id.uuidString, privacy: .public)")
                // 静默失败（对齐 H5 + Live/Call）
            }
        }
    }

    private func presentDeleteAction(for message: UnifiedPublicChatMessage) {
        guard canDeleteTextMessages,
              message.source != nil,
              case .text = message.variant else { return }
        deleteActionMessage = message
    }

    private func deleteMessage(_ message: UnifiedPublicChatMessage) {
        guard deletingMessageId == nil,
              let onDeleteTextMessage else { return }
        deletingMessageId = message.id
        Task { @MainActor in
            let deleted = await onDeleteTextMessage(message)
            deletingMessageId = nil
            deleteToast = deleted ? L10n.Party.messageDeleted : L10n.Party.deleteMessageFailed
        }
    }
}
