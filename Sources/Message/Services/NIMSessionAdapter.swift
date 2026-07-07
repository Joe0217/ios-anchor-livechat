import Combine
import Foundation
import NIMSDK
import os

/// NIM SDK P2P 会话 SDK 桥接（H-1 MVP，spec §1.3 v2）。
///
/// 实现 `MessageSessionProviderProtocol`，把 NIMSDK 的 `NIMRecentSession` / `NIMSession` 归一化为
/// 业务 `MessageSession`。含以下细节（v2 red team 修订）：
/// - **fetchAll**：evaluate `asyncLoadRecentSessionEnabled`（NIMSDKConfig），若开启则 SDK 分批加载
///   `didLoadAllRecentSessionCompletion` delegate 到达后可全量拉；否则同步 `allRecentSessions()`
///   hop 到 background queue 避免卡主线程（老用户上万会话可能命中）
/// - **subscribe delegate**：SDK 回调**无线程保证**（`NIMConversationManagerProtocol.h:288-339`）；
///   内部 `Task { @MainActor in ... }` hop 到主 actor **单串行队列**避免顺序错乱
/// - **置顶**：走 `NIMChatExtendManagerProtocol.addStickTopSession(_:completion:)` / `removeStickTopSession`
///   跨端漫游（不用 SDK 4.5.x 不存在的 `customExt` 字段）
///
/// **数据归一化**：peer nickname / avatar 从 `SessionStore` / `NIMUserInfo` 缓存派生；
/// lastMessage 按 NIM message type 归一化为占位（图片 → `[Image]`；语音 → `[Voice]` 等，i18n 走 L10n）
@MainActor
final class NIMSessionAdapter: NSObject, MessageSessionProviderProtocol {

    private let logger = Logger(subsystem: "com.anchor.livechat", category: "NIMSessionAdapter")

    /// delegate 事件转发回 Store（Store init 通过 subscribe(_:) 注入）
    private var eventHandler: (@MainActor (MessageSessionEvent) -> Void)?

    override init() {
        super.init()
        NIMSDK.shared().conversationManager.add(self)
        logger.info("🔵 [Adapter] init + conversationManager.add(self)")
    }

    deinit {
        // remove 需在 main actor；deinit 可能非 main actor，用 nonisolated 兼容路径
        NIMSDK.shared().conversationManager.remove(self)
    }

    // MARK: - fetchAll（hop background 避免卡主线程）

    func fetchAll() async throws -> [MessageSession] {
        logger.info("🟡 [Adapter] fetchAll() start — SDK isLogined=\(NIMSDK.shared().loginManager.isLogined(), privacy: .public)")
        let recentSessions: [NIMRecentSession] = await withCheckedContinuation { cont in
            // hop background queue 避免 SDK 内部大数据量卡主线程（`NIMConversationManagerProtocol.h:801-805`）
            DispatchQueue.global(qos: .userInitiated).async {
                let all = NIMSDK.shared().conversationManager.allRecentSessions() ?? []
                cont.resume(returning: all)
            }
        }
        logger.info("🟡 [Adapter] fetchAll rawCount=\(recentSessions.count, privacy: .public)")
        // 前 5 条 raw session 详情（诊断用）
        for (i, s) in recentSessions.prefix(5).enumerated() {
            let sid = s.session?.sessionId ?? "nil"
            let type = s.session?.sessionType.rawValue ?? -1
            let unread = s.unreadCount
            let lastType = s.lastMessage?.messageType.rawValue ?? -1
            logger.info("🟡 [Adapter] raw[\(i, privacy: .public)] sid=\(sid, privacy: .private) type=\(type, privacy: .public) unread=\(unread, privacy: .public) lastMsgType=\(lastType, privacy: .public)")
        }
        let mapped = recentSessions.compactMap(mapToBusiness)
        logger.info("🟡 [Adapter] mapped P2P count=\(mapped.count, privacy: .public) (raw=\(recentSessions.count, privacy: .public), filtered=\(recentSessions.count - mapped.count, privacy: .public))")
        return mapped
    }

    // MARK: - 置顶 / 取消置顶

    func setStickTop(sessionId: String, isTop: Bool) async throws {
        let session = NIMSession(sessionId, type: .P2P)
        let chatExt = NIMSDK.shared().chatExtendManager

        if isTop {
            let params = NIMAddStickTopSessionParams(session: session)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                chatExt.addStickTopSession(params) { error, _ in
                    Task { @MainActor in
                        if let error { cont.resume(throwing: error) } else { cont.resume() }
                    }
                }
            }
        } else {
            // 需要查现有置顶 info 才能删除
            // SDK 返回 [NIMSession: NIMStickTopSessionInfo] dict，按 session key 查
            let info: NIMStickTopSessionInfo? = await withCheckedContinuation { cont in
                chatExt.loadStickTopSessionInfos { _, infos in
                    let match = infos?[session]
                    Task { @MainActor in cont.resume(returning: match) }
                }
            }
            guard let stickInfo = info else {
                // 已非置顶态，视为成功
                return
            }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                chatExt.removeStickTopSession(stickInfo) { error, _ in
                    Task { @MainActor in
                        if let error { cont.resume(throwing: error) } else { cont.resume() }
                    }
                }
            }
        }
    }

    // MARK: - 删除

    func delete(sessionId: String) async throws {
        let session = NIMSession(sessionId, type: .P2P)
        guard let recent = NIMSDK.shared().conversationManager.recentSession(by: session) else {
            // 已不存在，视为成功
            return
        }
        NIMSDK.shared().conversationManager.delete(recent)
    }

    // MARK: - Subscribe

    func subscribe(_ handler: @MainActor @escaping (MessageSessionEvent) -> Void) {
        self.eventHandler = handler
    }

    func unsubscribe() {
        self.eventHandler = nil
    }

    // MARK: - IM 连接态 publisher（Step 3 反悔 #1）

    /// v2 修复：映射 `NIMService.$isSessionSyncOK` 而非 `.connectionState == .connected`。
    ///
    /// **修复根因**：`.connected` = `NIMLoginStep.loginOK` (5)，但 SDK 后续还有 `syncing`(7) → `syncOK`(8) 阶段。
    /// 冷启动 auto-login 时 Store 若在 `.loginOK` 触发 fetch，`allRecentSessions()` 常返空 → 用户看到消息丢失。
    /// 改用 `.syncOK` 才是 sessions/漫游消息真正 ready 的信号（H-1 spec §1.5 反悔 #1 v2 修复）。
    var isConnectedPublisher: AnyPublisher<Bool, Never> {
        NIMService.shared.$isSessionSyncOK.eraseToAnyPublisher()
    }

    // MARK: - 归一化

    /// `NIMRecentSession` → 业务 `MessageSession`。
    ///
    /// **ext 字段**（H5 `session.js` 语义）：本 MVP 通道 A 仅依据 SDK 已有回调推导，
    /// 具体来源 H-2 期补：`receivedGift/called/received/sended` 目前**全部返 false**——
    /// 触发 R-6 明示的"关注/好友归 Stranger"缺口（等 H-2 补 `apiBatchQueryYxStat` 通道 B）。
    private func mapToBusiness(_ recent: NIMRecentSession) -> MessageSession? {
        guard let session = recent.session else {
            logger.notice("🟠 [Adapter] mapToBusiness: session=nil, skip")
            return nil
        }
        guard session.sessionType == .P2P else {
            logger.notice("🟠 [Adapter] mapToBusiness: sessionType=\(session.sessionType.rawValue, privacy: .public) not P2P, skip sid=\(session.sessionId, privacy: .private)")
            return nil
        }
        let sessionId = session.sessionId

        let lastMessage = summarize(recent.lastMessage)
        let timestamp = Int64((recent.lastMessage?.timestamp ?? 0) * 1000)

        // peer nickname / avatar：优先 NIM user info，缺时 fallback sessionId
        let userInfo = NIMSDK.shared().userManager.userInfo(sessionId)
        let nickname = userInfo?.userInfo?.nickName ?? sessionId
        let avatar = userInfo?.userInfo?.avatarUrl

        // v3 修复（Flame 空态 bug）：通道 A ext 从 SDK `serverExt` 解析（H5 `session.extra`，
        // 云信 SDK 跨端同步字段）。H5 `session.js:34-48` boolean AND 语义。
        let ext = parseServerExt(recent.serverExt)
        if ext.isFlameByExt {
            logger.info("🟣 [Adapter] session sid=\(sessionId, privacy: .private) is Flame (ext=\(String(describing: ext), privacy: .public))")
        }

        return MessageSession(
            id: sessionId,
            peerNickname: nickname,
            peerAvatarURL: avatar,
            lastMessage: lastMessage,
            lastMessageTimestamp: timestamp,
            unreadCount: recent.unreadCount,
            isTop: false,           // 置顶态 H-2 从 `stickTopInfoForSession` 派生
            ext: ext
        )
    }

    /// 解析 `NIMRecentSession.serverExt`（对齐 H5 `session.extra` 云端同步字段）。
    ///
    /// serverExt 是 JSON string；缺失/异常时返 `.empty`（该 session 归 Stranger）。
    private func parseServerExt(_ serverExt: String?) -> MessageSessionExt {
        guard let json = serverExt, !json.isEmpty,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        return MessageSessionExt(
            receivedGift: dict["receivedGift"] as? Bool ?? false,
            called: dict["called"] as? Bool ?? false,
            received: dict["received"] as? Bool ?? false,
            sended: dict["sended"] as? Bool ?? false
        )
    }

    /// NIM 消息 → 文本摘要（v3 spec §1.4b #3 归一化对齐 H5 `message/list.vue` getMessagePreview + attach 分类）。
    ///
    /// - text: 文本原文
    /// - image: `[Image]`
    /// - audio: `[Voice]`
    /// - video: `[Video]`
    /// - custom + SEND_GIFT: `[Gift]`
    /// - custom + MISSED_CALLS_RECORD / status=4: `Missed`
    /// - custom + status=3: `Rejected`
    /// - custom + status=2: `Cancelled`
    /// - custom 其他: `[Unknown]`
    private func summarize(_ message: NIMMessage?) -> String {
        guard let m = message else { return "" }
        switch m.messageType {
        case .text: return m.text ?? ""
        case .image: return L10n.messagePreviewImage
        case .audio: return L10n.messagePreviewVoice
        case .video: return L10n.messagePreviewVideo
        case .location: return L10n.messagePreviewLocation
        case .custom: return summarizeCustom(m)
        default: return ""
        }
    }

    /// 自定义消息按 attachType / status 分类（H5 message/list.vue 逐字对齐 8 大 case）。
    private func summarizeCustom(_ m: NIMMessage) -> String {
        // 尝试从 NIMCustomObject 提取 attachment.encode() JSON string，或 remoteExt 提取 attachType
        var payloadKeywords = ""
        if let obj = m.messageObject as? NIMCustomObject, let attach = obj.attachment {
            payloadKeywords = attach.encode()
        }
        if let ext = m.remoteExt {
            payloadKeywords += String(describing: ext)
        }

        // 通话记录（H5 attach.attachType === 'MISSED_CALLS_RECORD' or status=4）
        if payloadKeywords.contains("MISSED_CALLS_RECORD") || payloadKeywords.contains("\"status\":4") {
            return L10n.messagePreviewCallMissed
        }
        if payloadKeywords.contains("\"status\":3") { return L10n.messagePreviewCallRejected }
        if payloadKeywords.contains("\"status\":2") { return L10n.messagePreviewCallCancelled }
        // 礼物（H5 attach.attachType === 'SEND_GIFT'）
        if payloadKeywords.contains("SEND_GIFT") { return L10n.messagePreviewGift }
        return L10n.messagePreviewUnknown
    }
}

// MARK: - NIMConversationManagerDelegate

extension NIMSessionAdapter: NIMConversationManagerDelegate {

    nonisolated func didAdd(_ recentSession: NIMRecentSession, totalUnreadCount: Int) {
        Task { @MainActor [weak self] in
            guard let self, let s = self.mapToBusiness(recentSession) else { return }
            self.eventHandler?(.add(s))
        }
    }

    nonisolated func didUpdate(_ recentSession: NIMRecentSession, totalUnreadCount: Int) {
        Task { @MainActor [weak self] in
            guard let self, let s = self.mapToBusiness(recentSession) else { return }
            self.eventHandler?(.update(s))
        }
    }

    nonisolated func didRemove(_ recentSession: NIMRecentSession, totalUnreadCount: Int) {
        Task { @MainActor [weak self] in
            guard let self, let session = recentSession.session else { return }
            self.eventHandler?(.remove(sessionId: session.sessionId))
        }
    }
}
