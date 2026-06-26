import Foundation

/// 礼物消息路由协议（H 里程碑 spec §3.2）。
///
/// **接口锁定**：本会话仅定义 protocol 签名 + 默认 route 分发；具体实现（SVGA/MP4 队列、PK 期重排、
/// 钻石福袋 UI、心愿单飘屏、活跃大 R 进场 Toast 等）由 **H 礼物会话**独立实施。
///
/// **职责划分**：
/// - 本会话：锁 attachType 通道归属 + handle* 入口签名 + 队列控制 API（enqueueGift / reorderDuringPK）
/// - 礼物会话：实现 4 个 handle* 方法解析 payload 入队、实现 SVGA 渲染、PK 期重排策略
///
/// **覆盖的 attachType**（H 校验清单 §1.1.2 礼物相关）：
/// - 礼物：1 / SEND_GIFT / 4 / 50 / 56 / 71 / 2049 / active_tycoon_enter_room
/// - 进场动画：80 / 83
/// - 心愿单：250 / 251 / 252 / 253
/// - 钻石福袋：1030 / 1031 / 1032 / 1033
@MainActor
protocol GiftMessageRouter: MessageRouter {

    // MARK: - route 入口（按 attachType 分组；payload 透传由礼物会话自解析）

    /// 礼物消息（chatroom + P2P 双通道）：1 / SEND_GIFT / 4 / 50 / 56 / 71 / 2049 / active_tycoon_enter_room
    func handleGiftMessage(_ attachType: AttachType, payload: [String: Any])

    /// 进场动画（虚拟道具 / 座驾）：80 / 83
    func handleEnterAnimation(_ attachType: AttachType, payload: [String: Any])

    /// 心愿单：250 / 251 / 252 / 253
    func handleWishlistMessage(_ attachType: AttachType, payload: [String: Any])

    /// 钻石福袋：1030 / 1031 / 1032 / 1033
    func handleDiamondBoxMessage(_ attachType: AttachType, payload: [String: Any])

    // MARK: - 动画队列控制（被 PKStoreObserver / 业务侧调用，不走 route 链路）

    /// 礼物动画队列入队（H 礼物会话内部 SVGA/MP4 加载 + 连击叠加判定）
    func enqueueGift(_ message: GiftMessage)

    /// PK 期间队列重排策略（由 `PKStoreObserver.didStartPK` / `didEndPK` 触发）
    /// - Parameter maxQueueLength: PK 期同屏播放数限制，0 表示暂停礼物动画
    func reorderDuringPK(maxQueueLength: Int)
}

extension GiftMessageRouter {

    /// 默认 route 实现：根据 attachType 分组分发到对应 handle* 方法。
    /// 礼物会话可整体覆盖本 default impl 自行实现路由策略。
    func route(_ attachType: AttachType,
               payload: [String: Any],
               context: MessageContext) -> Bool {
        switch attachType {
        case .sendGift, .liveCallGift, .liveGiftRankUpdate, .rankUpdateOnly,
             .hotScoreUpdate, .partyGiftCompressed, .activeTycoonEnter:
            handleGiftMessage(attachType, payload: payload)
            return true

        case .enterRoomAnimation, .privateCallEnterAnimation:
            handleEnterAnimation(attachType, payload: payload)
            return true

        case .wishlistFirst, .wishlistTop1, .wishlistPoolDone, .wishlistGiftDone:
            handleWishlistMessage(attachType, payload: payload)
            return true

        case .diamondBoxWarm, .diamondBoxOpen, .diamondBoxClaim, .diamondBoxSettle:
            handleDiamondBoxMessage(attachType, payload: payload)
            return true

        default:
            return false
        }
    }
}
