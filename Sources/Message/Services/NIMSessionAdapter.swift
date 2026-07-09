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

    /// **v6 对齐 H5**：数据源用 `allRecentSessions()`（对齐 H5 `nim.session.getSessions`，
    /// 云信 SDK 本地缓存，跨端已同步）。
    ///
    /// **关键过滤**（对齐 H5 `session.js:293`）：
    /// - `lastMessage` 必须非 nil 且 `timestamp > 0` —— 排除"无会话时间"的僵尸会话
    /// - `sessionType == .P2P` —— 排除群/超大群等其他类型
    ///
    /// **上限**（对齐 H5 `maxSessionCount = 200`）：只取时间倒序 top 200
    func fetchAll() async throws -> [MessageSession] {
        logger.info("🟡 [Adapter] fetchAll() start — SDK isLogined=\(NIMSDK.shared().loginManager.isLogined(), privacy: .public)")
        let recentSessions: [NIMRecentSession] = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let all = NIMSDK.shared().conversationManager.allRecentSessions() ?? []
                cont.resume(returning: all)
            }
        }
        logger.info("🟡 [Adapter] fetchAll rawCount=\(recentSessions.count, privacy: .public)")

        // 时间倒序 top 200（对齐 H5 maxSessionCount + slice(0, maxSessionCount)）
        let sorted = recentSessions
            .sorted { ($0.lastMessage?.timestamp ?? 0) > ($1.lastMessage?.timestamp ?? 0) }
            .prefix(200)

        let mapped = sorted.compactMap(mapToBusiness)
        logger.info("🟡 [Adapter] mapped P2P count=\(mapped.count, privacy: .public) (raw=\(recentSessions.count, privacy: .public), dropped=\(recentSessions.count - mapped.count, privacy: .public))")
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
    /// **过滤（对齐 H5 `session.js:293`）**：
    /// - `lastMessage != nil && timestamp > 0` —— 排除"无会话时间"的僵尸会话（H5 明确 filter）
    /// - `sessionType == .P2P` —— 排除群/超大群
    private func mapToBusiness(_ recent: NIMRecentSession) -> MessageSession? {
        guard let session = recent.session else {
            return nil
        }
        guard session.sessionType == .P2P else {
            return nil
        }
        // H5 `session.js:293-297` 明确：无 lastMsg 或 updateTime 的会话不入列表
        guard let lastMsg = recent.lastMessage, lastMsg.timestamp > 0 else {
            return nil
        }
        let sessionId = session.sessionId

        let lastMessage = summarize(lastMsg)
        let timestamp = Int64(lastMsg.timestamp * 1000)

        // peer nickname / avatar：优先 NIM user info
        let userInfo = NIMSDK.shared().userManager.userInfo(sessionId)
        let nickname = userInfo?.userInfo?.nickName ?? sessionId
        let avatar = userInfo?.userInfo?.avatarUrl

        // ext 通道 A —— serverExt 跨端同步（H5 session.extra 等价）
        let ext = parseServerExt(recent.serverExt)

        return MessageSession(
            id: sessionId,
            peerNickname: nickname,
            peerAvatarURL: avatar,
            lastMessage: lastMessage,
            lastMessageTimestamp: timestamp,
            unreadCount: recent.unreadCount,
            isTop: false,
            ext: ext
        )
    }

    /// 解析 `NIMRecentSession.serverExt`（对齐 H5 `session.extra` 云端同步字段）。
    ///
    /// serverExt 是 JSON string；缺失/异常时返 `.empty`（该 session 归 Stranger）。
    ///
    /// **类型兼容**：4 字段全部走 Bool/Int/String 三兼容
    /// （对齐 [.claude/rules/ios-decode-userid-compat.md](../../.claude/rules/ios-decode-userid-compat.md)
    /// 精神——H5 JS 弱类型 `=== true`，但云信 server ext 在跨端存储时字段可能落地为 Number 1/0 或 "true"/"false"）
    private func parseServerExt(_ serverExt: String?) -> MessageSessionExt {
        guard let json = serverExt, !json.isEmpty,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        return MessageSessionExt(
            receivedGift: parseBoolCompat(dict["receivedGift"]),
            called: parseBoolCompat(dict["called"]),
            received: parseBoolCompat(dict["received"]),
            sended: parseBoolCompat(dict["sended"]),
            activeTycoon: parseBoolCompat(dict["activeTycoon"])
        )
    }

    /// Bool/Int/String 三兼容 —— H5 `=== true` 严格但云信跨端存储字段类型不可控
    private func parseBoolCompat(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber {
            // NSNumber 桥接安全：objCType "c"/"B" = Bool，已在上面 as? Bool 捕获；此处按 int 取值
            return n.intValue != 0
        }
        if let s = any as? String {
            return s == "true" || s == "1"
        }
        return false
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
