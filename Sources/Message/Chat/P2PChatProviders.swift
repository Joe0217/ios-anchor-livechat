import Combine
import Foundation

/// P2P 聊天数据层 protocol（H-2 spec §2.1 + §3.1）。
///
/// **抽象目的**：让 `P2PChatStore` 完全脱离 NIMSDK 依赖，可测（Fakes 注入）、可 Preview（stub 注入）。
/// 生产实现由 `NIMChatAdapter`（`Sources/Message/Chat/Services/`）挂 `NIMChatManagerDelegate`。
///
/// **peerYxAccId 单会话作用域**：Provider 每次由 `P2PChatStore` 与某个对端绑定；跨会话切换需 new store。
@MainActor
protocol P2PChatProviderProtocol: AnyObject {

    /// 拉取历史（首屏 / 上拉分页）。
    /// - Parameters:
    ///   - peerYxAccId: 对端 yxAccId
    ///   - anchor: 分页 anchor（首屏 nil；上拉传当前最旧一条的 `ChatMessage.id`；SDK 层用 messageId 转 NIMMessage）
    ///   - limit: 每页条数（spec §4.6 = 20）
    /// - Returns: 消息数组（**未去重**，调用方按 messageId 去重合并）
    func fetchHistory(peerYxAccId: String, anchor: String?, limit: Int) async throws -> [ChatMessage]

    /// 发文字消息。SDK 返回 messageId 后调用方将乐观 message.id 从 clientMsgId 迁移到真 messageId。
    func sendText(peerYxAccId: String, text: String, clientMsgId: String) async throws -> String

    /// 发音频消息。SDK 内嵌上传（`NIMAudioObject initWithSourcePath`）—— provider 内部 progress 回调
    /// 走 delegate `didUpdateSending` 转发到 store 的 `.uploading` → `.sent`。
    /// - Parameters:
    ///   - localFilePath: 已 copy 到 chat 目录持久化的音频文件（防切后台系统清）
    ///   - dur: 秒数
    func sendAudio(peerYxAccId: String, localFilePath: String, dur: Int, clientMsgId: String) async throws -> String

    /// 发图片消息（**外链免上传**，spec §4.4 主路径 + S1 spike 确认 `NIMImageObject.setUploadURL`）。
    func sendImage(peerYxAccId: String, url: URL, clientMsgId: String) async throws -> String

    /// 发视频消息（**外链免上传**，同图片）。
    func sendVideo(peerYxAccId: String, url: URL, thumbnailUrl: URL?, dur: Int, clientMsgId: String) async throws -> String

    // MARK: - H-3 私密消息（spec §4.1 / Critical-2 / Critical-3）

    /// 发私密图片消息。**caller (Store) 先调 SendPrivateInfoService.fetchSignedData 拿 signedData**
    /// 传入；provider 内部组装 `remoteExt.privateMsg.data = signedData ∪ {userId, iconType, videoUrl}`
    /// + `remoteExt.chatBubble` / `remoteExt.activeTycoon`（从 `AnchorInfoStore.mine` 拉）。
    ///
    /// - Parameters:
    ///   - peerYxAccId: 对端 yxAccId
    ///   - peerUserId: 对端业务 userId（写入 `ext.data.userId`，H5 line 627 反直觉）
    ///   - url: 图片 CDN URL（NIM `sendImageMsg` 用）
    ///   - privateId: 后端派发业务 ID（`ext.data.privateId`，用于 checkPrivateInfo）
    ///   - signedData: SendPrivateInfoService 返回的 data dict（含 giftId/recordId/... 后端签发字段）
    ///   - clientMsgId: 乐观发送临时 id
    /// - Returns: NIM messageId
    func sendPrivateImage(
        peerYxAccId: String,
        peerUserId: String,
        url: URL,
        privateId: String,
        signedData: [String: Any],
        clientMsgId: String
    ) async throws -> String

    /// 发私密视频消息（同 sendPrivateImage；解密播放由 GiftMessageService.decryptVideoUrl 复用）。
    func sendPrivateVideo(
        peerYxAccId: String,
        peerUserId: String,
        url: URL,
        thumbnailUrl: URL?,
        dur: Int,
        privateId: String,
        signedData: [String: Any],
        clientMsgId: String
    ) async throws -> String

    /// 清本地 unread badge（不通知对端）。进页调。
    func markAllRead(peerYxAccId: String) async

    /// 给对端发已读回执（P2P 单条，参数是最后一条对端消息）。
    /// H5 `sendMsgReceipt({msg:lastMsg})` iOS 对应 `NIMChatManager.sendMessageReceipt:`。
    func sendReceipt(peerYxAccId: String, lastReceivedMessageId: String) async

    /// 订阅 SDK 增量事件。**@MainActor handler**：由 provider 保证回调在 main。
    func subscribe(_ handler: @MainActor @escaping (P2PChatEvent) -> Void)

    /// 停止订阅（view onDisappear 且非 background 时调，spec §4.8）。
    func unsubscribe()
}

/// SDK 增量事件（`NIMChatManagerDelegate` 归纳为 4 类）。
enum P2PChatEvent {
    /// 收到对端消息（onRecvMessages）
    case received([ChatMessage])
    /// 我方消息发送状态更新（deliveryState 变化：从 uploading → sent）
    case sendingProgress(clientMsgId: String, progress: Double)
    /// 我方消息发送完成（SDK 回填 messageId），或失败
    case sendingCompleted(clientMsgId: String, messageId: String?, error: SendError?)
    /// 对端已读回执（timestamp ≤ receipt.timestamp 的 outgoing 消息可升级 .sent → .read）
    case receiptReceived(timestamp: Int64)
}

/// 发送失败错误分类（对齐 H5 `err.code === 7101 → refused`）。
enum SendError: Error, Equatable {
    /// 被对端拉黑
    case refused(reason: String)
    /// 其他（网络 / SDK 内部）—— 可重发
    case retryable(errorCode: String?)
}
