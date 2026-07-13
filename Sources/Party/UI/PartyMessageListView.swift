import SwiftUI

/// 派对房公屏消息列表 + 最近一条送礼提示（review 202606252033 P1-6 拆出）。
///
/// 拆出原因：
/// - `chat.messages` 高频变化（活跃房 >5 条/秒）每次都触发整个 PartyRoomView body 重算
/// - 顶层 body 重算 → seatGrid + LazyVGrid 重新 evaluate → PartyRemoteVideoView / CameraPreview 抖动
/// - 抽到独立子 view 后，@ObservedObject chat 仅触发本子 view 重 evaluate；麦位区完全不受影响
///
/// 入参：
/// - chat: 观测 messages + 历史拉取状态
/// - lastGiftEvent: 仅显示最近一条送礼（落公屏，不归入 chat.messages 数据流）
///
/// v23（2026-07-13）：加翻译（对齐 H5 messageScroller CTranslate + PublicChatListView / CallMessageScroller）：
/// - 只对方（`isLocal == false`）+ 未翻译的文本消息显示翻译图标
/// - tap 图标 → 调 MicrosoftTranslateService → chat.setTranslation
/// - 目标语言取自 AppLocaleStore.shared.current；失败静默
struct PartyMessageListView: View {
    @ObservedObject var chat: PartyRoomChatManager
    /// v10：按 tab 过滤消息（对齐 H5 + Android 派对房 All/Chat/Gift 三档，用户 2026-07-13 confirm 蓝本存在）
    /// - .all: 全部原样
    /// - .chat: 排除 .gift 类，保留 .text / .welcome / .convention（用户可感知的聊天流）
    /// - .gift: 仅 .gift 类
    var filter: PartyRoomChatFilter = .all
    let lastGiftEvent: PartyGiftEvent?
    /// 防重入 map:正在翻译中的 msgId(对齐 PublicChatListView.pendingTranslateIds)
    @State private var pendingTranslateIds: Set<UUID> = []

    /// 过滤后的消息列表（对齐 H5/Android tab 过滤语义）
    private var filteredMessages: [PartyChatMessage] {
        switch filter {
        case .all:
            return chat.messages
        case .chat:
            return chat.messages.filter { $0.msgType != .gift }
        case .gift:
            return chat.messages.filter { $0.msgType == .gift }
        }
    }

    /// gift banner 仅在 All / Gift tab 显示；Chat tab 隐藏（避免 gift 混入纯聊天视图）
    private var showGiftBanner: Bool { filter != .chat }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(filteredMessages) { msg in
                        messageRow(msg).id(msg.id)
                    }
                    if showGiftBanner, let g = lastGiftEvent {
                        Text(String(format: L10n.Party.giftMessageFormat,
                                    g.senderNickname ?? L10n.Party.defaultUser,
                                    g.giftName ?? L10n.Party.defaultGift,
                                    g.num))
                            .font(.system(size: 13))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 12)
                            .id("gift_\(g.timestamp)")
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: chat.messages.count) { _ in
                if let last = filteredMessages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: .infinity)
        // 设计稿视觉重排后聊天区盖在 room 背景大图上，systemBackground（dark 下不透明黑）会抹掉底图；
        // 改用 clear 让底图透出。若未来某处需要不透明底可外层包装挂 background。
    }

    private func messageRow(_ msg: PartyChatMessage) -> some View {
        // 翻译图标只对"对方文本消息 + 未翻译"显示(对齐 H5 `!isSelf` + text)
        // v24（2026-07-13）:改 inline 图标跟随文字末尾(用户反馈)
        let showTranslateInline = !msg.isLocal && msg.msgType == .text && msg.translation == nil && !msg.text.isEmpty
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                inlineText(nickname: msg.nickname,
                           text: msg.text,
                           roleColor: msg.role == .owner ? .orange : .blue,
                           showTranslateInline: showTranslateInline)
                Spacer(minLength: 0)
                if msg.isLocal {
                    Image(systemName: "clock").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            if let t = msg.translation, !t.isEmpty {
                Text(t)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if showTranslateInline { handleTapTranslate(msg: msg) }
        }
        .accessibilityAddTraits(showTranslateInline ? .isButton : [])
    }

    /// v24: 昵称 + 正文 + (可选)inline 翻译图标 concat(SwiftUI Text 支持 Image attachment)
    private func inlineText(nickname: String?,
                            text: String,
                            roleColor: Color,
                            showTranslateInline: Bool) -> some View {
        let nickTx: Text = {
            if let n = nickname, !n.isEmpty {
                return Text("\(n): ").foregroundColor(roleColor)
            }
            return Text("")
        }()
        let bodyTx = Text(text).foregroundColor(.white)
        let iconTx = Text(" ") + Text(Image(systemName: "character.book.closed.fill"))
            .foregroundColor(Color(red: 196/255, green: 155/255, blue: 1.0)) // #C49BFF
        return Group {
            if showTranslateInline {
                Text("\(nickTx)\(bodyTx)\(iconTx)")
            } else {
                Text("\(nickTx)\(bodyTx)")
            }
        }
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)
    }

    /// tap 翻译处理:防重入 + 调 MicrosoftTranslateService + chat.setTranslation
    private func handleTapTranslate(msg: PartyChatMessage) {
        guard !pendingTranslateIds.contains(msg.id) else { return }
        pendingTranslateIds.insert(msg.id)
        let key = AppConfigStore.shared.microsoftTranslatorKey ?? AppConfigStore.translatorKeyFallback
        let area = AppConfigStore.shared.microsoftTranslatorArea ?? AppConfigStore.translatorAreaFallback
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
                    text: msg.text, targetLang: targetLang, key: key, area: area
                )
                chat.setTranslation(messageId: msg.id, translation: translated)
            } catch {
                AppLogger.party.warning("[PartyChat] translate failed msgId=\(msg.id.uuidString, privacy: .public)")
                // 静默失败(对齐 H5 + PublicChatListView + CallMessageScroller)
            }
        }
    }
}
