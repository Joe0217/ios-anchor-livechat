import Foundation
import NIMSDK
import os

/// 公屏一条消息。
struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isSystem: Bool
}

/// 云信聊天室（独立模式）：进房 + 收公屏文本 + 进出房在线人数。
/// 对应 H5 useCallApi.joinChatRoom + live.js chatroomLiveChatRecordMsg。
/// 礼物等自定义消息(attachType=50)需注册自定义附件解析，先占位显示。
///
/// 线程模型（对齐 PartyRoomChatManager）：整类 @MainActor，NIM SDK 子线程回调
/// (`onRecvMessages` / `chatroom(_:connectionStateChanged:)`) 标 `nonisolated`，
/// 函数体仅 `Task { @MainActor }` 切回主 actor 后执行 `processIncoming` 等业务逻辑。
/// 不再混用 DispatchQueue.main.async（@MainActor 已保证主线程）。
@MainActor
final class NIMChatroomManager: NSObject, ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var onlineCount: Int = 0
    @Published var connected = false

    private var roomId = ""
    private static var didSetup = false

    /// G M4-3：PKNIMRouter weak 注入；onRecvMessages 收到 attachType 97/98/99/100/-8/-9 时路由到 PKStore
    weak var pkRouter: PKNIMRouter?

    /// 兜底：LiveRoomView.onDisappear 的 leave() 受 scenePhase + state 双守卫，logout / 路由切换等
    /// 非 .ended 路径下 view 销毁会跳过 leave；deinit 在此强制注销 NIMSDK delegate 防回调残留。
    /// NIMSDK delegate 注销 API 不需要 main actor 隔离（SDK 内部串行化）。
    /// 聊天室 exitChatroom 不在此调（避免 deinit 读 @MainActor 字段），由云信自然超时退房。
    deinit {
        NIMSDK.shared().chatManager.remove(self)
        NIMSDK.shared().chatroomManager.remove(self)
    }

    /// 全局初始化：注册 appKey + 通用自定义消息解码器（只一次）。
    /// H M1：实际工作转移到 `NIMService.setupOnce`，本方法保留作 forwarder 避免破坏旧调用点。
    static func setupOnce() {
        guard !didSetup else { return }
        didSetup = true
        NIMService.setupOnce()
    }

    /// 对齐 H5：先 IM 登录（nim.connect），再进聊天室（依赖 IM 通道，非独立模式）。
    /// account=yxAccid，token=imToken（H5 注释「云信密码」，即静态 token 鉴权）。
    func enter(roomId: String, nickname: String, account: String, token: String) {
        NIMChatroomManager.setupOnce()
        self.roomId = roomId
        AppLogger.im.debug("🟣 [Chatroom] IM 登录 account=\(account, privacy: .public) tokenLen=\(token.count, privacy: .private)")
        NIMSDK.shared().chatManager.add(self)
        NIMSDK.shared().chatroomManager.add(self)

        // 已登录则直接进房；否则先登录
        if NIMSDK.shared().loginManager.isLogined() {
            enterChatroom(roomId: roomId, nickname: nickname)
        } else {
            NIMSDK.shared().loginManager.login(account, token: token) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error = error {
                        let code = (error as NSError).code
                        AppLogger.im.error("🔴 [Chatroom] IM 登录失败 code=\(code, privacy: .public) \(error.localizedDescription, privacy: .private)")
                        self.push(String(format: L10n.imSystemLoginFailedFormat, "\(code)"), system: true)
                        return
                    }
                    AppLogger.im.info("🟢 [Chatroom] IM 登录成功，进聊天室")
                    self.enterChatroom(roomId: roomId, nickname: nickname)
                }
            }
        }
    }

    /// 进聊天室（mode=nil，复用 IM 长连接自动取地址，无需独立模式地址回调）。
    private func enterChatroom(roomId: String, nickname: String) {
        let request = NIMChatroomEnterRequest()
        request.roomId = roomId
        request.roomNickname = nickname
        request.retryCount = 3

        NIMSDK.shared().chatroomManager.enterChatroom(request) { [weak self] error, chatroom, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error = error {
                    let code = (error as NSError).code
                    AppLogger.im.error("🔴 [Chatroom] 进房失败 code=\(code, privacy: .public) \(error.localizedDescription, privacy: .private)")
                    self.push(String(format: L10n.imSystemJoinFailedFormat, "\(code)"), system: true)
                } else {
                    AppLogger.im.info("🟢 [Chatroom] 进房成功 online=\(chatroom?.onlineUserCount ?? 0, privacy: .public)")
                    self.connected = true
                    self.onlineCount = chatroom?.onlineUserCount ?? 0
                    self.push(L10n.imSystemJoined, system: true)
                }
            }
        }
    }

    func leave() {
        guard !roomId.isEmpty else { return }
        NIMSDK.shared().chatManager.remove(self)
        NIMSDK.shared().chatroomManager.remove(self)
        NIMSDK.shared().chatroomManager.exitChatroom(roomId, completion: nil)
        roomId = ""
        connected = false
    }

    private func push(_ text: String, system: Bool) {
        messages.append(ChatMessage(text: text, isSystem: system))
        if messages.count > 80 { messages.removeFirst(messages.count - 80) }
    }

    /// 收公屏消息后的统一处理（main actor）。
    /// 路径：(1) PK 业务字段 `remoteExt.attachType` 走 PKNIMRouter；
    /// (2) 文本 / 通知 / 占位礼物 push 到 messages；(3) enter/exit 维护 onlineCount。
    fileprivate func processIncoming(_ batch: [NIMMessage]) {
        var items: [ChatMessage] = []
        var delta = 0
        for m in batch {
            guard m.session?.sessionType == .chatroom else { continue }
            // G M4 真根因修复：PK 业务字段走 NIM `remoteExt`（对应 H5 `msgItem.ext`，live.js:223 parseMessageExt），
            // 不是 custom attachment。试 2 条 fallback 路径：(1) remoteExt 顶层；(2) attachment.encode() JSON 内
            var pkPayload: [String: Any]? = nil
            if let ext = m.remoteExt as? [String: Any], ext["attachType"] != nil {
                pkPayload = ext
            } else if m.messageType == .custom,
                      let obj = m.messageObject as? NIMCustomObject,
                      let attach = obj.attachment {
                let raw = attach.encode()
                if let data = raw.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   parsed["attachType"] != nil {
                    pkPayload = parsed
                }
            }
            // 调试：把 chatroom custom 消息形态全 dump，方便后续抓 backend payload 真实结构
            if m.messageType == .custom {
                AppLogger.im.notice("🟣 [PK debug] custom msg remoteExt=\(String(describing: m.remoteExt), privacy: .private) hasPayload=\(pkPayload != nil, privacy: .public)")
            }
            if let payload = pkPayload {
                let at = AttachType(raw: payload["attachType"])
                switch at {
                case .pkInvite, .pkScoreUpdate, .pkInviteAck, .pkStatusBundle,
                     .pkMuteBroadcast, .pkChatNotice:
                    pkRouter?.route(at, payload: payload)
                    if at == .pkChatNotice, let txt = payload["content"] as? String, !txt.isEmpty {
                        items.append(ChatMessage(text: txt, isSystem: true))
                    }
                    continue
                default:
                    break
                }
            }
            switch m.messageType {
            case .text:
                let name = m.senderName ?? ""
                let body = m.text ?? ""
                items.append(ChatMessage(text: name.isEmpty ? body : "\(name)：\(body)", isSystem: false))
            case .custom:
                // G M4：分发 attachType 97/98/99/100/-8/-9 到 PKNIMRouter；其他（礼物 1/4/15/18 / 合规 44/61/62/63）暂保持 placeholder（H 阶段做礼物动画）
                if let obj = m.messageObject as? NIMCustomObject,
                   let attach = obj.attachment as? GenericCustomAttachment {
                    let at = AttachType(raw: attach.rawDict["attachType"])
                    switch at {
                    case .pkInvite, .pkScoreUpdate, .pkInviteAck, .pkStatusBundle,
                         .pkMuteBroadcast, .pkChatNotice:
                        pkRouter?.route(at, payload: attach.rawDict)
                        // attachType=-9 公屏文本由 payload.content 直接展示（H5 同行为）
                        if at == .pkChatNotice, let txt = attach.rawDict["content"] as? String, !txt.isEmpty {
                            items.append(ChatMessage(text: txt, isSystem: true))
                        }
                    default:
                        items.append(ChatMessage(text: L10n.imSystemGiftPlaceholder, isSystem: true))
                    }
                } else {
                    items.append(ChatMessage(text: L10n.imSystemGiftPlaceholder, isSystem: true))
                }
            case .notification:
                if let obj = m.messageObject as? NIMNotificationObject,
                   let content = obj.content as? NIMChatroomNotificationContent {
                    if content.eventType == .enter {
                        delta += 1
                        items.append(ChatMessage(text: L10n.userJoined, isSystem: true))
                    } else if content.eventType == .exit {
                        delta -= 1
                    }
                }
            default:
                break
            }
        }
        guard !items.isEmpty || delta != 0 else { return }
        for it in items { push(it.text, system: it.isSystem) }
        if delta != 0 { onlineCount = max(0, onlineCount + delta) }
    }
}

// MARK: - 收消息（NIMSDK 回调，非 main actor → Task 切回）

extension NIMChatroomManager: NIMChatManagerDelegate {
    nonisolated func onRecvMessages(_ messages: [NIMMessage]) {
        Task { @MainActor [weak self] in
            self?.processIncoming(messages)
        }
    }
}

// MARK: - 连接状态

extension NIMChatroomManager: NIMChatroomManagerDelegate {
    nonisolated func chatroom(_ roomId: String, connectionStateChanged state: NIMChatroomConnectionState) {
        // 可按需处理重连/断开（占位；与 PartyRoomChatManager 对称的 nonisolated 回调）
    }
}
