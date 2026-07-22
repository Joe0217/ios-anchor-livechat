import SwiftUI
import os

private let translateLogger = Logger(subsystem: "com.anchor.livechat", category: "public-chat-translate")

/// 跨场景公屏消息列表容器。使用方：
/// ```
/// PublicChatListView(feed: myFeed, theme: .live)
/// ```
///
/// v23（2026-07-12）：内建翻译能力（对齐 H5 `messageScroller.vue` CTranslate）：
/// - 对方普通文字消息（`.text` variant + `sender?.isSelf == false`）显示翻译图标
/// - tap 图标 → 调 `MicrosoftTranslateService` → `feed.setTranslation(...)`
/// - 目标语言取自 `AppLocaleStore.shared.current`（.en/.ar/.tr）
/// - 失败静默（公屏 UX 无 toast，对齐 H5 也无失败提示）
struct PublicChatListView: View {
    @ObservedObject var feed: UnifiedPublicChatFeed
    let theme: PublicChatTheme
    /// 关闭翻译（如系统消息 feed / 派对房 sub-mode 特殊需求）
    var translationEnabled: Bool = true
    /// v24（B4 · 对齐 H5 §9.12.4）：Screen 公屏 @回复 回调；nil = 关闭 hi 气泡功能
    var onScreenReply: ((UnifiedPublicChatMessage) -> Void)? = nil
    /// v24（B4）：MSG 半屏私聊回调；nil = 关闭 hi 气泡的 MSG 分支（Screen 仍可 wired）
    var onMsgOpen: ((UnifiedPublicChatMessage) -> Void)? = nil

    /// 防重入 map：正在翻译中的 msgId（避免用户狂点重复请求）
    @State private var pendingTranslateIds: Set<UUID> = []
    /// v24 B4：当前弹 hi 动作 confirmationDialog 的目标消息（同一时刻至多 1 个）
    @State private var hiActionMsg: UnifiedPublicChatMessage? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: theme.rowSpacing) {
                    ForEach(feed.messages.suffix(theme.suffixCount)) { msg in
                        PublicChatRow(
                            message: msg,
                            theme: theme,
                            onTapTranslate: translationEnabled ? handleTapTranslate : nil,
                            isTranslating: pendingTranslateIds.contains(msg.id),
                            onTapHi: hiEnabled ? handleTapHi : nil
                        ).id(msg.id)
                    }
                }
                .padding(.horizontal, theme.horizontalInset)
                .padding(.bottom, theme.bottomInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.containerBackground)
            .onChange(of: feed.messages.count, perform: handleMessagesCountChange(proxy: proxy))
            .confirmationDialog(
                nicknameForHiDialog,
                isPresented: Binding(
                    get: { hiActionMsg != nil },
                    set: { if !$0 { hiActionMsg = nil } }
                ),
                titleVisibility: .visible
            ) {
                hiDialogButtons
            }
        }
    }

    /// hi 气泡功能启用门禁：至少 Screen 或 MSG 之一非 nil
    private var hiEnabled: Bool { onScreenReply != nil || onMsgOpen != nil }

    private var nicknameForHiDialog: String {
        hiActionMsg?.sender?.nickname ?? ""
    }

    @ViewBuilder
    private var hiDialogButtons: some View {
        if let msg = hiActionMsg {
            if let cb = onScreenReply {
                Button(L10n.publicScreenHiScreen) {
                    cb(msg)
                    hiActionMsg = nil
                }
            }
            if let cb = onMsgOpen {
                Button(L10n.publicScreenHiMsg) {
                    cb(msg)
                    hiActionMsg = nil
                }
            }
            Button(L10n.commonCancel, role: .cancel) {
                hiActionMsg = nil
            }
        }
    }

    private func handleTapHi(_ msg: UnifiedPublicChatMessage) {
        hiActionMsg = msg
    }

    private func handleMessagesCountChange(proxy: ScrollViewProxy) -> (Int) -> Void {
        { _ in
            guard let last = feed.messages.last else { return }
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    private func handleTapTranslate(_ msg: UnifiedPublicChatMessage) {
        // 只处理 .text variant；防重入 map hit 短路
        guard case .text(let content, _, let existing, _) = msg.variant,
              existing == nil,
              !pendingTranslateIds.contains(msg.id),
              !content.isEmpty else { return }
        pendingTranslateIds.insert(msg.id)

        // 防御：AppConfigStore 冷启动竞态时回落 hardcode fallback（对齐 ChatDetailView.handleTranslate）
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
                    text: content, targetLang: targetLang, key: key, area: area
                )
                feed.setTranslation(messageId: msg.id, translation: translated)
            } catch {
                translateLogger.warning("[PublicChat] translate failed msgId=\(msg.id.uuidString, privacy: .public) err=\(String(describing: error), privacy: .public)")
                // 公屏 UX 无 toast（对齐 H5 messageScroller 静默失败）
            }
        }
    }
}
