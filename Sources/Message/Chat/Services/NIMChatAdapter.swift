import Combine
import Foundation
import NIMSDK
import os

private let chatLogger = Logger(subsystem: "com.anchor.livechat", category: "NIMChatAdapter")

/// P2P 消息级 SDK 桥（H-2 spec §0.4 + §3.1，red team #1 补齐）。
///
/// **为什么必须新建**：`NIMSessionAdapter` 只挂 `NIMConversationManagerDelegate`（会话级）；
/// 私聊页需要的**消息级事件**（收/发/回执）走 `NIMChatManagerDelegate`，本类专挂。
///
/// **单会话作用域**：每 `ChatDetailView` `@StateObject P2PChatStore` 时构造一个 adapter；
/// tearDown 时 unsubscribe。生命周期与 store 一致。
@MainActor
final class NIMChatAdapter: NSObject, P2PChatProviderProtocol {

    // MARK: - 输入

    private let peerYxAccId: String
    private let selfYxAccId: String

    /// SDK 层 messageId → 本地 clientMsgId 反查表（progress/didComplete 回调用）
    private var messageIdToClientId: [String: String] = [:]

    private var eventHandler: (@MainActor (P2PChatEvent) -> Void)?

    // MARK: - 生命周期

    init(peerYxAccId: String, selfYxAccId: String) {
        self.peerYxAccId = peerYxAccId
        self.selfYxAccId = selfYxAccId
        super.init()
    }

    // MARK: - Provider protocol

    func fetchHistory(peerYxAccId: String, anchor: String?, limit: Int) async throws -> [ChatMessage] {
        let session = NIMSession(peerYxAccId, type: .P2P)
        let anchorMsg: NIMMessage? = anchor.flatMap { anchorId in
            NIMSDK.shared().conversationManager
                .messages(in: session, messageIds: [anchorId])?.first
        }

        // Batch 3.9：我方历史消息需补上当前穿戴的 chatBubble（MainActor 内取好，capture 到 SDK 回调闭包）
        let selfChatBubble = Self.currentSelfChatBubble()
        return await withCheckedContinuation { [selfYxAccId, selfChatBubble] cont in
            NIMSDK.shared().conversationManager.messages(
                in: session, message: anchorMsg, limit: limit
            ) { error, messages in
                if let error {
                    // 只是本地 db 拉不到；返空数组由 caller 判 empty；不 throw
                    _ = error   // 保留供后续埋点
                    cont.resume(returning: [])
                    return
                }
                let converted = (messages ?? []).compactMap { nimMsg in
                    ChatMessageMapper.map(nimMsg, selfYxAccId: selfYxAccId, selfChatBubble: selfChatBubble)
                }
                cont.resume(returning: converted)
            }
        }
    }

    func sendText(peerYxAccId: String, text: String, clientMsgId: String) async throws -> String {
        let msg = NIMMessage()
        msg.text = text
        // Batch 3.9：主播透传 chatBubble + activeTycoon 到 remoteExt(H5 chatMsg 同源),对端 msgItem 用来渲染气泡背景 + nav 徽章
        msg.remoteExt = Self.buildRegularRemoteExt()
        return try registerAndSend(msg, clientMsgId: clientMsgId)
    }

    /// 普通消息（text/image/video/audio）remoteExt 组装 —— 只透传 chatBubble + activeTycoon
    /// 私密消息走 buildPrivateRemoteExt(extensionType='privateMsg')
    private static func buildRegularRemoteExt() -> [String: Any]? {
        guard let mine = AnchorInfoStore.shared.mine else { return nil }
        var ext: [String: Any] = [:]
        if let bubble = mine.chatBubble, !bubble.isEmpty {
            ext["chatBubble"] = bubble
        }
        if let tycoon = mine.activeTycoon {
            ext["activeTycoon"] = tycoon
        }
        guard !ext.isEmpty else { return nil }
        // Major-12: JSON isValid 守卫（同 buildPrivateRemoteExt 一致）
        return JSONSerialization.isValidJSONObject(ext) ? ext : nil
    }

    func sendAudio(peerYxAccId: String, localFilePath: String, dur: Int, clientMsgId: String) async throws -> String {
        let audio = NIMAudioObject(sourcePath: localFilePath)
        audio.duration = dur * 1000   // 毫秒
        let msg = NIMMessage()
        msg.messageObject = audio
        return try registerAndSend(msg, clientMsgId: clientMsgId)
    }

    func sendImage(peerYxAccId: String, url: URL, clientMsgId: String) async throws -> String {
        // NIMSDK 10.10.0 拒绝空 filepath（NIMLocalErrorCodeInvalidPicture code=3）——
        // 必须先下载到本地 tmp，再走 setUploadURL(CDN) 让 SDK 跳过实际重传
        let localPath = try await Self.downloadToTmp(remote: url, defaultExt: "jpg")
        let image = NIMImageObject(filepath: localPath)
        image.setUploadURL(url.absoluteString)
        let msg = NIMMessage()
        msg.messageObject = image
        return try registerAndSend(msg, clientMsgId: clientMsgId)
    }

    func sendVideo(peerYxAccId: String, url: URL, thumbnailUrl: URL?, dur: Int, clientMsgId: String) async throws -> String {
        let localPath = try await Self.downloadToTmp(remote: url, defaultExt: "mp4")
        let video = NIMVideoObject(sourcePath: localPath)
        video.setUploadURL(url.absoluteString)
        video.duration = dur
        let msg = NIMMessage()
        msg.messageObject = video
        return try registerAndSend(msg, clientMsgId: clientMsgId)
    }

    /// 下载 CDN 媒体到 tmp file（NIMSDK filepath 必须是本地合法文件）。
    ///
    /// - Parameter defaultExt: URL 无扩展名时的兜底扩展（图片 jpg / 视频 mp4）。
    /// - Returns: 本地 filesystem path（非 URL）
    private static func downloadToTmp(remote: URL, defaultExt: String) async throws -> String {
        if remote.isFileURL { return remote.path }
        let (data, _) = try await URLSession.shared.data(from: remote)
        let ext = remote.pathExtension.isEmpty ? defaultExt : remote.pathExtension
        let tmpUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("nim_\(UUID().uuidString).\(ext)")
        try data.write(to: tmpUrl)
        chatLogger.info("downloadToTmp OK bytes=\(data.count) path=\(tmpUrl.lastPathComponent, privacy: .public)")
        return tmpUrl.path
    }

    // MARK: - H-3 私密消息发送（spec §4.1 / Critical-2 / Critical-3 / Major-4 / Major-12）

    func sendPrivateImage(
        peerYxAccId: String,
        peerUserId: String,
        url: URL,
        privateId: String,
        signedData: [String: Any],
        clientMsgId: String
    ) async throws -> String {
        let localPath = try await Self.downloadToTmp(remote: url, defaultExt: "jpg")
        let image = NIMImageObject(filepath: localPath)
        image.setUploadURL(url.absoluteString)
        let msg = NIMMessage()
        msg.messageObject = image
        msg.remoteExt = Self.buildPrivateRemoteExt(
            peerUserId: peerUserId, iconType: 1, mediaUrl: url, videoUrl: nil, signedData: signedData
        )
        return try registerAndSend(msg, clientMsgId: clientMsgId)
    }

    func sendPrivateVideo(
        peerYxAccId: String,
        peerUserId: String,
        url: URL,
        thumbnailUrl: URL?,
        dur: Int,
        privateId: String,
        signedData: [String: Any],
        clientMsgId: String
    ) async throws -> String {
        let localPath = try await Self.downloadToTmp(remote: url, defaultExt: "mp4")
        let video = NIMVideoObject(sourcePath: localPath)
        video.setUploadURL(url.absoluteString)
        video.duration = dur
        let msg = NIMMessage()
        msg.messageObject = video
        msg.remoteExt = Self.buildPrivateRemoteExt(
            peerUserId: peerUserId, iconType: 2, mediaUrl: url, videoUrl: url, signedData: signedData
        )
        return try registerAndSend(msg, clientMsgId: clientMsgId)
    }

    /// 组装 remoteExt.privateMsg + chatBubble + activeTycoon（Major-4 主播透传）
    /// **对齐 H5**（`chat/index.vue:624-631`）：
    /// - data = signedData ∪ {userId: peerUserId, iconType, videoUrl (视频)}
    /// - **不写 lockStatus**（Critical-2：服务端追加）
    /// - remoteExt = {extensionType: 'privateMsg', data} + chatBubble + activeTycoon
    /// - **Major-12** 塞前 JSONSerialization.isValidJSONObject 守卫
    private static func buildPrivateRemoteExt(
        peerUserId: String,
        iconType: Int,
        mediaUrl: URL,
        videoUrl: URL?,
        signedData: [String: Any]
    ) -> [String: Any] {
        var extData = signedData
        extData["userId"] = peerUserId                       // H5 line 627 反直觉
        extData["iconType"] = iconType
        if iconType == 2, let vurl = videoUrl {
            extData["videoUrl"] = vurl.absoluteString
        }
        // Critical-2: 不写 lockStatus

        var remoteExt: [String: Any] = [
            "extensionType": "privateMsg",
            "data": extData,
        ]

        // Major-4：透传 chatBubble + activeTycoon（对端徽章三级 fallback 之三 / 气泡背景）
        if let mine = AnchorInfoStore.shared.mine {
            if let bubble = mine.chatBubble, !bubble.isEmpty {
                remoteExt["chatBubble"] = bubble
            }
            if let tycoon = mine.activeTycoon {
                remoteExt["activeTycoon"] = tycoon
            }
        }

        // Major-12: JSON isValid 守卫（NIMSDK remoteExt 塞 NSNull 会崩，同 CLAUDE.md 已知坑）
        guard JSONSerialization.isValidJSONObject(remoteExt) else {
            // fallback 最小合法结构
            return ["extensionType": "privateMsg", "data": ["userId": peerUserId, "iconType": iconType]]
        }
        return remoteExt
    }

    func markAllRead(peerYxAccId: String) async {
        let session = NIMSession(peerYxAccId, type: .P2P)
        // NIMSDK Swift async variant，try? 静默错误（本地清 unread 失败不影响主流程）
        try? await NIMSDK.shared().conversationManager.markAllMessagesRead(in: session)
    }

    func sendReceipt(peerYxAccId: String, lastReceivedMessageId: String) async {
        let session = NIMSession(peerYxAccId, type: .P2P)
        guard let lastMsg = NIMSDK.shared().conversationManager
                .messages(in: session, messageIds: [lastReceivedMessageId])?.first else {
            return
        }
        let receipt = NIMMessageReceipt(message: lastMsg)
        // NIMSDK OC 接口 `sendMessageReceipt:completion:` 自动桥接为 Swift async throws；本地回执失败不影响主流程
        try? await NIMSDK.shared().chatManager.send(receipt)
    }

    func subscribe(_ handler: @MainActor @escaping (P2PChatEvent) -> Void) {
        self.eventHandler = handler
        NIMSDK.shared().chatManager.add(self)
    }

    func unsubscribe() {
        NIMSDK.shared().chatManager.remove(self)
        eventHandler = nil
        messageIdToClientId.removeAll()
    }

    deinit {
        // ChatManager 是 shared，非本 adapter 独占，deinit 时应 remove delegate
        NIMSDK.shared().chatManager.remove(self)
    }

    // MARK: - 内部：发送前 register clientMsgId → messageId 映射

    private func registerAndSend(_ msg: NIMMessage, clientMsgId: String) throws -> String {
        let session = NIMSession(peerYxAccId, type: .P2P)
        messageIdToClientId[msg.messageId] = clientMsgId

        do {
            try NIMSDK.shared().chatManager.send(msg, to: session)
            chatLogger.info("send OK clientMsgId=\(clientMsgId) messageId=\(msg.messageId) kind=\(String(describing: type(of: msg.messageObject)))")
            return msg.messageId
        } catch {
            messageIdToClientId.removeValue(forKey: msg.messageId)
            let nsError = error as NSError
            chatLogger.error("send FAILED clientMsgId=\(clientMsgId) code=\(nsError.code) domain=\(nsError.domain) userInfo=\(nsError.userInfo, privacy: .private)")
            throw SendError.retryable(errorCode: "\(nsError.code)")
        }
    }
}

// MARK: - NIMChatManagerDelegate（消息级）

extension NIMChatAdapter: NIMChatManagerDelegate {

    /// SDK 发送进度（audio/image/video 上传）
    nonisolated func send(_ message: NIMMessage, progress: Float) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let clientMsgId = self.messageIdToClientId[message.messageId] else { return }
            self.eventHandler?(.sendingProgress(clientMsgId: clientMsgId, progress: Double(progress)))
        }
    }

    /// SDK 发送完成（成功 or 失败）
    nonisolated func send(_ message: NIMMessage, didCompleteWithError error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let clientMsgId = self.messageIdToClientId[message.messageId] else { return }
            self.messageIdToClientId.removeValue(forKey: message.messageId)

            if let error = error as NSError? {
                chatLogger.error("didComplete FAILED clientMsgId=\(clientMsgId) code=\(error.code) domain=\(error.domain) kind=\(String(describing: type(of: message.messageObject)))")
                let sendErr: SendError = (error.code == 7101)
                    ? .refused(reason: "blocked_by_peer")
                    : .retryable(errorCode: "\(error.code)")
                self.eventHandler?(.sendingCompleted(clientMsgId: clientMsgId, messageId: nil, error: sendErr))
            } else {
                chatLogger.info("didComplete OK clientMsgId=\(clientMsgId) messageId=\(message.messageId)")
                self.eventHandler?(.sendingCompleted(clientMsgId: clientMsgId, messageId: message.messageId, error: nil))
            }
        }
    }

    /// 收到对端消息
    nonisolated func onRecvMessages(_ messages: [NIMMessage]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let relevant = messages.filter { $0.session?.sessionId == self.peerYxAccId }
            // Batch 3.9：我方历史消息需补上当前穿戴的 chatBubble（MainActor 内取，作为参数传给 nonisolated map）
            let selfChatBubble = Self.currentSelfChatBubble()
            let converted = relevant.compactMap {
                ChatMessageMapper.map($0, selfYxAccId: self.selfYxAccId, selfChatBubble: selfChatBubble)
            }
            // Task 11：Chat 场景收到 SEND_GIFT 礼物 → 接入跨场景礼物特效引擎（有 svga/mp4 时弹中央大动画；
            // 消息气泡由现有 SystemGiftBubbleView + ChatMessageMapper 已 map 到 .systemGift 独立承担）
            let mineYxAccid = SessionStore.shared.user?.yxAccid ?? ""
            for nim in relevant where nim.messageType == .custom {
                guard let raw = nim.rawAttachContent,
                      let data = raw.data(using: .utf8),
                      let attach = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                // 2026-07-09 review 反悔加固：attachType 双形态兼容（字符串 "SEND_GIFT" or 数字 1）
                // 对齐 AttachType.sendGift 定义；ios-decode-userid-compat 精神
                let atStr = attach["attachType"] as? String
                let atNum = (attach["attachType"] as? NSNumber)?.intValue
                if atStr == "SEND_GIFT" || atNum == 1 {
                    // 2026-07-09 fix pre-existing：NIMChatAdapter 无 self.peerYxAccid 字段；
                    // 从 NIMMessage.session.sessionId 取（P2P 场景 sessionId 即对端 yxAccid）。
                    let peer = nim.session?.sessionId ?? ""
                    chatLogger.debug("[Chat] SEND_GIFT intake peer=\(peer, privacy: .public) keys=\(attach.keys.joined(separator: ","), privacy: .public)")
                    GiftEffectIntake.ingest(scene: .chat, scopeId: peer, payload: attach, mineYxAccid: mineYxAccid)
                }
            }
            guard !converted.isEmpty else { return }
            self.eventHandler?(.received(converted))
        }
    }

    /// MainActor 内取自己当前穿戴的 chatBubble URL（供 map 调用方注入 —— map 是 nonisolated）
    private static func currentSelfChatBubble() -> URL? {
        guard let bubble = AnchorInfoStore.shared.mine?.chatBubble, !bubble.isEmpty else { return nil }
        return URL(string: bubble)
    }

    /// 对端已读回执
    nonisolated func onRecvMessageReceipts(_ receipts: [NIMMessageReceipt]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let relevant = receipts.filter { $0.session?.sessionId == self.peerYxAccId }
            guard let latest = relevant.max(by: { $0.timestamp < $1.timestamp }) else { return }
            let tsMs = Int64(latest.timestamp * 1000)
            self.eventHandler?(.receiptReceived(timestamp: tsMs))
        }
    }
}

// MARK: - NIMMessage → ChatMessage 映射

enum ChatMessageMapper {

    /// - Parameter selfChatBubble: 我方当前穿戴的 chatBubble URL；nonisolated 上下文调用，需由 MainActor 侧调用方预取传入（避免 AnchorInfoStore.shared @MainActor 隔离冲突）
    static func map(_ nim: NIMMessage, selfYxAccId: String, selfChatBubble: URL? = nil) -> ChatMessage? {
        guard let content = mapContent(nim) else { return nil }

        let isOutgoing = nim.isOutgoingMsg
        // 会话对端 yxAccId（P2P）
        let peerYxAccId = nim.session?.sessionId ?? ""
        let from = isOutgoing ? selfYxAccId : (nim.from ?? peerYxAccId)
        let to = isOutgoing ? peerYxAccId : selfYxAccId

        var msg = ChatMessage(
            id: nim.messageId,
            clientMsgId: nil,   // SDK 历史消息不含本地 clientMsgId
            from: from,
            to: to,
            content: content,
            status: mapStatus(nim),
            timestamp: Int64(nim.timestamp * 1000),
            isOutgoing: isOutgoing
        )
        // Batch 3.9：从 remoteExt 解出对端穿戴的 chatBubble（TextBubbleView 用于渲染气泡背景）
        // 对方消息 → 用对方 chatBubble；我方消息 → 保持自己气泡由 optimistic 层写入的值（此处不覆盖）
        if !isOutgoing {
            // NIMMessage.remoteExt 是 [AnyHashable: Any]?；parser 期望 [String: Any]?，需类型强转
            msg.chatBubble = MessageAttachParser.extractChatBubble(remoteExt: nim.remoteExt as? [String: Any])
        } else if let url = selfChatBubble {
            // 我方历史消息（重新登录 / 拉历史时无 optimistic 值）用调用方传入的当前穿戴气泡
            msg.chatBubble = url
        }
        return msg
    }

    private static func mapContent(_ nim: NIMMessage) -> ChatMessageContent? {
        switch nim.messageType {
        case .text:
            return .text(nim.text ?? "")
        case .image:
            guard let img = nim.messageObject as? NIMImageObject,
                  let urlString = img.url, let url = URL(string: urlString) else { return nil }
            let size = img.size == .zero ? nil : img.size
            return .image(url: url, size: size)
        case .video:
            guard let vid = nim.messageObject as? NIMVideoObject,
                  let urlString = vid.url, let url = URL(string: urlString) else { return nil }
            let cover = vid.coverUrl.flatMap { URL(string: $0) }
            return .video(url: url, thumbnail: cover, dur: vid.duration)
        case .audio:
            guard let audio = nim.messageObject as? NIMAudioObject,
                  let urlString = audio.url, let url = URL(string: urlString) else { return nil }
            return .audio(url: url, dur: audio.duration / 1000)   // NIM 存毫秒 → 秒
        case .custom:
            // H-2 spec §2.4：走 MessageAttachParser 双分支分发
            // SEND_GIFT / MISSED_CALLS_RECORD / weakTxtType 数字系统提示 → 特化 case；
            // 其他未识别 attachType → `.system(rawJSON:)` 保原数据留 H-3+ 扩展
            let raw = nim.rawAttachContent ?? "{}"
            if let data = raw.data(using: .utf8),
               let attach = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return MessageAttachParser.parseCustom(attach, rawJSON: raw)
            }
            return .system(rawJSON: raw)
        default:
            return .system(rawJSON: "{}")
        }
    }

    private static func mapStatus(_ nim: NIMMessage) -> ChatMessageStatus {
        // 拉历史时初次映射：deliveryState 决定发送态，isRemoteRead 决定对端已读态。
        // NIMMessage.h:280 契约 —— isRemoteRead 仅 P2P outgoing 有效；未加 isOutgoingMsg 守卫时
        // 底层实现虽然对非 outgoing 稳定返 NO，仍显式守卫保对齐 SDK 文档语义。
        // 进入页面后对端新到的回执由 P2PChatStore.handleReceipt 事件驱动，与本函数不冲突。
        switch nim.deliveryState {
        case .delivering: return .sending
        case .deliveried:
            if nim.isOutgoingMsg && nim.isRemoteRead {
                return .read
            }
            return .sent
        case .failed: return .failed(errorCode: nil)
        @unknown default: return .sent
        }
    }
}
