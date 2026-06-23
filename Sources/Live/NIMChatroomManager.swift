import Foundation
import NIMSDK

/// 公屏一条消息。
struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isSystem: Bool
}

/// 云信聊天室（独立模式）：进房 + 收公屏文本 + 进出房在线人数。
/// 对应 H5 useCallApi.joinChatRoom + live.js chatroomLiveChatRecordMsg。
/// 礼物等自定义消息(attachType=50)需注册自定义附件解析，先占位显示。
final class NIMChatroomManager: NSObject, ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var onlineCount: Int = 0
    @Published var connected = false

    private var roomId = ""
    private static var didSetup = false

    /// 全局初始化：注册 appKey（只一次）
    static func setupOnce() {
        guard !didSetup else { return }
        didSetup = true
        let option = NIMSDKOption(appKey: AppConfig.nimAppKey)
        NIMSDK.shared().register(with: option)
    }

    /// 对齐 H5：先 IM 登录（nim.connect），再进聊天室（依赖 IM 通道，非独立模式）。
    /// account=yxAccid，token=imToken（H5 注释「云信密码」，即静态 token 鉴权）。
    func enter(roomId: String, nickname: String, account: String, token: String) {
        NIMChatroomManager.setupOnce()
        self.roomId = roomId
        print("🟣 [Chatroom] IM 登录 account=\(account) tokenLen=\(token.count) appKey=\(AppConfig.nimAppKey)")
        NIMSDK.shared().chatManager.add(self)
        NIMSDK.shared().chatroomManager.add(self)

        // 已登录则直接进房；否则先登录
        if NIMSDK.shared().loginManager.isLogined() {
            enterChatroom(roomId: roomId, nickname: nickname)
        } else {
            NIMSDK.shared().loginManager.login(account, token: token) { [weak self] error in
                guard let self else { return }
                if let error = error {
                    let code = (error as NSError).code
                    print("🔴 [Chatroom] IM 登录失败 code=\(code) \(error)")
                    DispatchQueue.main.async {
                        self.push(String(format: L10n.imSystemLoginFailedFormat, "\(code)"), system: true)
                    }
                    return
                }
                print("🟢 [Chatroom] IM 登录成功，进聊天室")
                self.enterChatroom(roomId: roomId, nickname: nickname)
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
            DispatchQueue.main.async {
                guard let self else { return }
                if let error = error {
                    let code = (error as NSError).code
                    print("🔴 [Chatroom] 进房失败 code=\(code) \(error)")
                    self.push(String(format: L10n.imSystemJoinFailedFormat, "\(code)"), system: true)
                } else {
                    print("🟢 [Chatroom] 进房成功 online=\(chatroom?.onlineUserCount ?? 0)")
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
}

// MARK: - 收消息

extension NIMChatroomManager: NIMChatManagerDelegate {
    func onRecvMessages(_ messages: [NIMMessage]) {
        var items: [ChatMessage] = []
        var delta = 0
        for m in messages {
            guard m.session?.sessionType == .chatroom else { continue }
            switch m.messageType {
            case .text:
                let name = m.senderName ?? ""
                let body = m.text ?? ""
                items.append(ChatMessage(text: name.isEmpty ? body : "\(name)：\(body)", isSystem: false))
            case .custom:
                items.append(ChatMessage(text: L10n.imSystemGiftPlaceholder, isSystem: true))
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
        DispatchQueue.main.async {
            for it in items { self.push(it.text, system: it.isSystem) }
            if delta != 0 { self.onlineCount = max(0, self.onlineCount + delta) }
        }
    }
}

// MARK: - 连接状态

extension NIMChatroomManager: NIMChatroomManagerDelegate {
    func chatroom(_ roomId: String, connectionStateChanged state: NIMChatroomConnectionState) {
        // 可按需处理重连/断开
    }
}
