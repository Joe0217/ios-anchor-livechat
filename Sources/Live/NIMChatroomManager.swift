import Foundation
import NIMSDK
import os

/// 公屏一条消息。
struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isSystem: Bool
}

/// 公屏消息独立 ObservableObject：与 LiveStore.networkDebugStore 同模式。
/// 让 `NIMChatroomManager.objectWillChange` 不因每条公屏消息发射，避免 LiveRoomView 整树重渲染
/// （review P1-3）。子 view `PublicScreenList` 直接订阅本 store，append 仅触发子 view 重算。
@MainActor
final class ChatMessagesStore: ObservableObject {
    @Published var messages: [ChatMessage] = []

    func append(_ msg: ChatMessage, limit: Int = 80) {
        messages.append(msg)
        if messages.count > limit { messages.removeFirst(messages.count - limit) }
    }
}

/// 在线人数独立 ObservableObject（review 202606260029 P1-1）：onlineCount 在 .enter/.exit 通知下
/// >1Hz 变化，原 @Published 挂在 NIMChatroomManager 上会触发 LiveRoomView 整树（CameraPreview /
/// RemoteVideoView / PKOverlayHost / publicScreen）重算。抽出独立 store 后仅 topBar 子 view
/// `OnlineCountText` 订阅，本体 LiveRoomView 不受影响。
@MainActor
final class ChatPresenceStore: ObservableObject {
    @Published var onlineCount: Int = 0
}

/// 直播云信聊天室（独立模式）：进/退房 + 公屏文本 + 在线人数 + 路由分发。
///
/// H M5 简化（207 → ~130 行）：
/// - 删 IM 登录代码：登录由 `NIMOnlineKeeper.start` 统一处理（spec §3 / NIMService.login）
/// - 删 `weak pkRouter` 字段：M2 后所有 router 走 `NIMService.shared.registerRouter`，dispatch 通过协议
/// - `onRecvMessages` 改走 `NIMService.shared.dispatch(_:payload:context:.liveChatroom)`：router 链路按 protocol 短路
/// - `setupOnce` 改 forwarder（保留旧调用点兼容；实际工作转 `NIMService.setupOnce`）
///
/// 线程模型：整类 `@MainActor`，NIMSDK 子线程回调（`onRecvMessages` / `chatroom(_:connectionStateChanged:)`）
/// 标 `nonisolated`，函数体仅 `Task { @MainActor }` 切回主 actor。
@MainActor
final class NIMChatroomManager: NSObject, ObservableObject {
    /// 公屏消息独立 store；子 view 订阅，append 不触发 LiveRoomView 整树重渲染。
    let messagesStore = ChatMessagesStore()
    /// 在线人数独立 store（review 202606260029 P1-1）：>1Hz 变化字段抽出，子 view 内观测。
    let presenceStore = ChatPresenceStore()
    /// 长连接态；当前无 view 订阅（grep 0 命中），保留为普通字段供内部状态机使用，不发 publish。
    private(set) var connected = false

    private var roomId = ""
    private var hasJoined = false   // 防止重复 enter 导致 NIMSDK delegate 重复 add → 公屏双播

    /// 兜底：LiveRoomView.onDisappear 的 leave() 受 scenePhase + state 双守卫，logout / 路由切换等
    /// 非 .ended 路径下 view 销毁会跳过 leave；deinit 在此强制注销 NIMSDK delegate 防回调残留。
    deinit {
        NIMSDK.shared().chatManager.remove(self)
        NIMSDK.shared().chatroomManager.remove(self)
    }

    /// 进聊天室。**前置**：NIMSDK 已由 `NIMOnlineKeeper.start` 完成 login；本方法不再 login。
    /// H M5：account / token 参数删除，调用点 (LiveRoomView) 同步简化。
    func enter(roomId: String, nickname: String) {
        guard !hasJoined else {
            AppLogger.im.notice("[Chatroom] already joined room=\(self.roomId, privacy: .public), skip enter")
            return
        }
        hasJoined = true
        NIMService.setupOnce()
        self.roomId = roomId
        AppLogger.im.debug("🟣 [Chatroom] enter roomId=\(roomId, privacy: .public) nickname=\(nickname, privacy: .private)")
        NIMSDK.shared().chatManager.add(self)
        NIMSDK.shared().chatroomManager.add(self)

        guard NIMSDK.shared().loginManager.isLogined() else {
            AppLogger.im.error("🔴 [Chatroom] IM 未登录，无法进房；NIMOnlineKeeper.start 应先于 enter 调用")
            push(String(format: L10n.imSystemLoginFailedFormat, "0"), system: true)
            rollbackEnterFailure()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let chatroom = try await NIMService.shared.enterChatroom(roomId: roomId, nickname: nickname)
                self.connected = true
                self.presenceStore.onlineCount = chatroom?.onlineUserCount ?? 0
                self.push(L10n.imSystemJoined, system: true)
                AppLogger.im.info("🟢 [Chatroom] enter ok online=\(self.presenceStore.onlineCount, privacy: .public)")
            } catch let err as NIMServiceError {
                if case let .chatroomEnterFailed(code, _) = err {
                    self.push(String(format: L10n.imSystemJoinFailedFormat, "\(code)"), system: true)
                }
                self.rollbackEnterFailure()
            } catch {
                self.push(String(format: L10n.imSystemJoinFailedFormat, "-1"), system: true)
                self.rollbackEnterFailure()
            }
        }
    }

    /// review 202606260029 P2-3：enter 失败两条路径（IM 未登录 / enterChatroom 抛错）必须回滚
    /// hasJoined + 已 add 的 NIMSDK delegate + roomId，否则用户重试 enter() 会被 `guard !hasJoined`
    /// 永久 skip，且残留 delegate 在 leave() 前持续接收同 roomId 消息。
    private func rollbackEnterFailure() {
        NIMSDK.shared().chatManager.remove(self)
        NIMSDK.shared().chatroomManager.remove(self)
        roomId = ""
        hasJoined = false
        connected = false
    }

    func leave() {
        guard !roomId.isEmpty else { return }
        NIMSDK.shared().chatManager.remove(self)
        NIMSDK.shared().chatroomManager.remove(self)
        NIMSDK.shared().chatroomManager.exitChatroom(roomId, completion: nil)
        roomId = ""
        connected = false
        hasJoined = false
    }

    private func push(_ text: String, system: Bool) {
        messagesStore.append(ChatMessage(text: text, isSystem: system))
    }

    /// 收公屏消息（main actor）。H M5：自定义消息分发统一走 `NIMService.dispatch`，
    /// 路由器按 protocol 短路决定消费；公屏文本副作用（-9 pkChatNotice）由本方法兼顾。
    fileprivate func processIncoming(_ batch: [NIMMessage]) {
        var items: [ChatMessage] = []
        var delta = 0

        for m in batch {
            // 双过滤（对齐 PartyRoomChatManager.belongsToThisRoom）：仅本聊天室且本 roomId 的消息进流程。
            // 防多 chatManager delegate 共存时（如同时持有直播 + 派对房）串消息。
            guard let s = m.session,
                  s.sessionType == .chatroom,
                  s.sessionId == roomId else { continue }

            // 提取自定义消息 payload（remoteExt 顶层 / attachment.rawDict / attachment.encode JSON）
            var payload: [String: Any]?
            if let ext = m.remoteExt as? [String: Any], ext["attachType"] != nil {
                payload = ext
            } else if m.messageType == .custom,
                      let obj = m.messageObject as? NIMCustomObject {
                if let attach = obj.attachment as? GenericCustomAttachment {
                    payload = attach.rawDict
                } else if let attach = obj.attachment {
                    let raw = attach.encode()
                    if let data = raw.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       parsed["attachType"] != nil {
                        payload = parsed
                    }
                }
            }

            if let payload {
                let at = AttachType(raw: payload["attachType"])
                // H M5：路由统一走 NIMService.dispatch；PKNIMRouter / GiftMessageRouter / SystemMessageRouter
                // 等按 protocol 短路决定消费
                NIMService.shared.dispatch(at, payload: payload, context: .liveChatroom(roomId: roomId))

                // 公屏文本副作用：-9 pkChatNotice 的 content 直接展示
                if at == .pkChatNotice, let txt = payload["content"] as? String, !txt.isEmpty {
                    items.append(ChatMessage(text: txt, isSystem: true))
                    continue
                }
                // 其他 PK 消息已 dispatch，不进公屏
                switch at {
                case .pkInvite, .pkScoreUpdate, .pkInviteAck, .pkStatusBundle, .pkMuteBroadcast:
                    continue
                case .knownButUnhandled, .unknown:
                    // 已知但不实现（132/133/1004/1007/1014/...）+ unknown：仅静默 dispatch（router 已分发），不污染公屏
                    continue
                default:
                    // 礼物 / 合规等 H 阶段仍占位显示（H 礼物会话接 SVGA 后改）
                    if m.messageType == .custom {
                        items.append(ChatMessage(text: L10n.imSystemGiftPlaceholder, isSystem: true))
                        continue
                    }
                }
            }

            // 文本 / notification（无 payload）
            switch m.messageType {
            case .text:
                let name = m.senderName ?? ""
                let body = m.text ?? ""
                items.append(ChatMessage(text: name.isEmpty ? body : "\(name)：\(body)", isSystem: false))
            case .custom:
                // 解码失败兜底
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
        for it in items { push(it.text, system: it.isSystem) }
        if delta != 0 {
            presenceStore.onlineCount = max(0, presenceStore.onlineCount + delta)
        }
    }
}

// MARK: - 收消息 / 连接状态（NIMSDK 子线程回调）

extension NIMChatroomManager: NIMChatManagerDelegate {
    nonisolated func onRecvMessages(_ messages: [NIMMessage]) {
        Task { @MainActor [weak self] in
            self?.processIncoming(messages)
        }
    }
}

extension NIMChatroomManager: NIMChatroomManagerDelegate {
    nonisolated func chatroom(_ roomId: String, connectionStateChanged state: NIMChatroomConnectionState) {
        // M5：长连接 / 重连状态由 NIMService.connectionState 全局承担；本回调暂留占位
    }
}
