#if canImport(NIMSDK)
import Foundation
import NIMSDK
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "GlobalP2PMessageObserver")

/// 全局 P2P 自定义消息 observer（对齐 H5 `message.js:186-232` + `handleUserRechargeNotification`）。
///
/// **为什么必须新建**（v3 v4 已有 3 类监听均不适用）：
/// - `NIMSessionAdapter` 只挂**会话级** `NIMConversationManagerDelegate`，不接消息内容
/// - `NIMChatAdapter` 挂**消息级** `NIMChatManagerDelegate` 但**作用域只限当前 chat 详情页**（每 ChatDetailContainer 一实例）
/// - `NIMChatroomManager` 只处理**直播公屏聊天室**消息
/// - **主播端需要"无论主播在哪个 tab"都能收到的全局 P2P 消息处理**（充值通知、CP 榜奖励等）
///
/// **职责范围**（保持最小）：
/// - 只处理**跨会话合成**类系统通知（H5 `attachType == 35` 用户充值成功）
/// - 收到后合成一条 NIMMessage → `saveMessage(_:forSession:)` 塞进 notification 会话本地库
/// - SDK 内部会 fire didAdd/didUpdate → `NIMSessionAdapter` 已订阅 → Flame 顶部 System 入口 unread+1 + lastMessage
///
/// **原样透传**：绝大多数消息（用户发的私聊 / 已经 from=notificationAccount 的消息）由 SDK 自身 delivery，
/// 本 observer 只做"合成注入"类**主动写库**操作，不干扰 SDK 天然消息流。
///
/// **生命周期**（rule session-scoped-store-refresh）：
/// - `SessionStore.login()` → `.shared.activate()`（addDelegate）
/// - `SessionStore.logout()` → `.shared.deactivate()`（removeDelegate）
/// - 单例；跨账号切换无残留 delegate
@MainActor
final class GlobalP2PMessageObserver: NSObject {

    static let shared = GlobalP2PMessageObserver()

    private var isActive: Bool = false

    private override init() { super.init() }

    /// SessionStore.login 成功后调用
    func activate() {
        guard !isActive else { return }
        NIMSDK.shared().chatManager.add(self)
        isActive = true
        logger.info("🟢 [GlobalP2P] activated")
    }

    /// SessionStore.logout 调用
    func deactivate() {
        guard isActive else { return }
        NIMSDK.shared().chatManager.remove(self)
        isActive = false
        logger.info("⚪ [GlobalP2P] deactivated")
    }
}

// MARK: - NIMChatManagerDelegate

extension GlobalP2PMessageObserver: NIMChatManagerDelegate {

    /// 全局 P2P 消息回调 —— 只拦"跨会话合成"类系统通知；其他原样交给 SDK
    nonisolated func onRecvMessages(_ messages: [NIMMessage]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for msg in messages {
                self.processIncomingMessage(msg)
            }
        }
    }

    private func processIncomingMessage(_ nim: NIMMessage) {
        // 只处理自定义消息类型
        guard nim.messageType == .custom else { return }

        // 解析 attach → attachType
        guard let rawAttach = nim.rawAttachContent,
              let data = rawAttach.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let attachType = Self.extractAttachType(dict)

        // 用户充值成功系统通知（对齐 H5 message.js:811-815 + handleUserRechargeNotification）
        if attachType == 35 {
            synthesizeRechargeNotification(originalMessage: nim, attach: dict)
        }
    }

    /// 合成一条充值通知消息塞进 notification P2P 会话（对齐 H5 handleUserRechargeNotification）。
    ///
    /// H5 流程：
    /// 1. 构造 msgObj { from: VITE_NOTIFICATION_SEEION_ID, attach, body: attach.content, ... }
    /// 2. addMsgToMsgArr（塞本地消息数组）
    /// 3. sessionStore.onUpdateSession（unread+1 + lastMsg）
    ///
    /// iOS 等价：**用 custom message 落地保留完整 attach**(对齐 H5 `type: 'custom'`) —— 让 ChatMessageMapper.mapContent
    /// 走 `.custom` 分支 → MessageAttachParser 识别 attachType=35 → `.rechargeNotify` 完整渲染 ID 链接跳转。
    /// SDK 自动 fire didAdd → NIMSessionAdapter 订阅 → MessageSessionStore 更新 Flame 顶部 System 入口。
    private func synthesizeRechargeNotification(originalMessage: NIMMessage, attach: [String: Any]) {
        let notifyAccId = AppConfig.notificationYxAccId
        let session = NIMSession(notifyAccId, type: .P2P)

        // 用 GenericCustomAttachment 承载完整 attach dict —— 保 attachType/content/userId/yxAccid 全字段
        guard JSONSerialization.isValidJSONObject(attach),
              let jsonData = try? JSONSerialization.data(withJSONObject: attach),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            logger.error("[GlobalP2P] synthesizeRechargeNotification attach JSON encode failed")
            return
        }
        let attachment = GenericCustomAttachment(rawDict: attach, rawJSON: jsonStr)
        let customObject = NIMCustomObject()
        customObject.attachment = attachment
        let msg = NIMMessage()
        msg.messageObject = customObject
        // 兜底把 content 也塞 remoteExt(旧客户端 fallback,新客户端走 rawDict)
        if let content = attach["content"] as? String, !content.isEmpty {
            msg.remoteExt = ["rechargeContentFallback": content]
        }

        NIMSDK.shared().conversationManager.save(msg, for: session) { error in
            if let error {
                logger.error("[GlobalP2P] saveMessage failed: \(String(describing: error), privacy: .private)")
            } else {
                logger.info("[GlobalP2P] recharge notification synthesized attachType=35 sessionId=\(notifyAccId, privacy: .private)")
            }
        }
    }

    /// H5 attach.attachType 可能是 Int / String，双兼容解析
    private static func extractAttachType(_ dict: [String: Any]) -> Int? {
        if let i = dict["attachType"] as? Int { return i }
        if let s = dict["attachType"] as? String, let i = Int(s) { return i }
        return nil
    }
}
#endif
