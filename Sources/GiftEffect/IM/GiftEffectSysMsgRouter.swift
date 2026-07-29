import Foundation

/// 通话礼物相关系统消息 router。
///
/// H5 当前行为：
/// - 直播场景礼物走 `liveChatroom` 通道 attachType=50，由 NIMChatroomManager 内部处理
/// - 已接通通话的收礼走带发送方的 P2P `SEND_GIFT`，由 GlobalP2PMessageObserver 按对端过滤
/// - attachType=4 缺发送方身份，已接通通话中跳过，不能作为旧协议猜测额外渲染
/// - 本 router 只处理用户拒绝主播索礼的系统消息
@MainActor
final class GiftEffectSysMsgRouter: MessageRouter {

    static let shared = GiftEffectSysMsgRouter()

    private init() {}

    func route(_ attachType: AttachType,
               payload: [String: Any],
               context: MessageContext) -> Bool {
        switch context {
        case .sysMsg, .syncSysMsg:
            break
        default:
            return false
        }

        // v22（2026-07-10）：主播索取礼物被用户拒绝 → toast
        if attachType == .giftRequestRejected {
            let callState = CallStore.shared.state
            guard callState != .idle && callState != .ended && callState != .failed else {
                return false
            }
            CallStore.shared.showAskForGiftRejected()
            return false
        }

        // 保持非独占，继续让其余系统消息 router 按自身职责处理。
        return false
    }
}
