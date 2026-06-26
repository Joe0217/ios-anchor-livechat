import Foundation

/// 云信 IM 消息分发的抽象层（H 里程碑 spec §2.2）。
///
/// 多个 `MessageRouter` 通过 `NIMService` 串联，各自挑感兴趣的 `AttachType` 处理。
/// NIMService 维护 `[MessageRouter]` 顺序数组，收到消息后按顺序调 `route`；
/// 第一个返回 `true` 的 router 消费后链路终止（短路）。
///
/// **顺序约定**（spec §2.2）：
/// PKNIMRouter（G）→ PartyMessageRouter → GiftMessageRouter（H 礼物会话）→ SystemMessageRouter → 兜底
///
/// **弱引用持有**：NIMService 通过 `WeakRouter` 包装存储，避免 router 与 store 之间的循环引用；
/// 业务方（如 LiveRoomView）在 onAppear 注入、onDisappear 注销，router 的强引用由 store 持有。
@MainActor
protocol MessageRouter: AnyObject {
    /// 处理一条消息。
    /// - Parameters:
    ///   - attachType: 解码后的 attachType 枚举（unknown / knownButUnhandled 视为不消费）
    ///   - payload: NIM `remoteExt` 或 customAttachment 解出来的业务字典；派对房 gzip 已由 NIMService 解压
    ///   - context: 消息通道上下文（区分 99 在 chatroom 与 sysMsg 通道下含义不同等场景）
    /// - Returns: `true` 表示已消费（链路终止），`false` 表示传给下游 router
    func route(_ attachType: AttachType,
               payload: [String: Any],
               context: MessageContext) -> Bool
}

/// 消息通道上下文（H 里程碑 spec §2.2）。
///
/// 通道区分对部分 attachType 必要：
/// - 99：chatroomMsg 通道 = pkInviteAck；sysMsg 通道 = AGENT_RECHARGE_NOTIFY（H5 形态）
/// - 默认 AttachType 数字 99 归 pkInviteAck，sysMsg 接代充时需在 SystemMessageRouter 内按 context 转译
///
/// 同时承载 roomId / fromAccount 等辅助信息，便于 router 内做业务级路由。
enum MessageContext {
    /// 直播聊天室（独立模式 / 复用 IM 长连接）
    case liveChatroom(roomId: String)
    /// 派对房聊天室
    case partyChatroom(roomId: String)
    /// P2P 私聊
    case p2p(fromAccount: String)
    /// 在线系统消息（`nim.on('sysMsg', ...)`）
    case sysMsg
    /// 离线/漫游系统消息批量补发（`nim.on('syncSysMsgs', ...)`，throttle 后逐条 dispatch）
    case syncSysMsg
}

/// NIMService 内部存储 `MessageRouter` 弱引用的包装。
///
/// 非泛型 `Weak<T>` 是为避免 Swift 对 protocol existential 做泛型实例化的限制——
/// `protocol MessageRouter: AnyObject` 已是类绑定，但 `Weak<MessageRouter>` 在 Swift 5.7+
/// 仍需显式 `any`。本类型直接持 `AnyObject?` 弱引用，存取时统一桥到 `any MessageRouter`。
@MainActor
final class WeakRouter {
    private weak var value: AnyObject?

    init(_ router: any MessageRouter) {
        self.value = router as AnyObject
    }

    /// 返回弱引用解出的 router；若已释放返回 nil（NIMService 在 dispatch 时跳过）。
    var router: (any MessageRouter)? {
        value as? any MessageRouter
    }

    /// 判断弱引用是否已释放，用于 NIMService 周期性清扫 routers 数组。
    var isAlive: Bool {
        value != nil
    }
}
