import Foundation

/// GiftEffect sysMsg 通道 router：仅处理 `.liveCallGift`（attachType=4，1v1 通话内对方送礼）
///
/// 背景（2026-07-09 真机反悔）：
/// - 直播场景礼物走 `liveChatroom` 通道 attachType=50，由 NIMChatroomManager 内部处理
/// - **Call 场景礼物走 sysMsg 通道 attachType=4**——需在 NIMService dispatch 链上有 router 消费，
///   否则 log 显示 `[NIMService] dispatch 4 ctx=sysMsg — no router consumed` 消息落地无声
///
/// **scope 一致性**：CallView modifier 挂 `scopeId: store.current.callId ?? ""`；
/// 本 router 也用 `CallStore.shared.current.callId ?? ""`—— 都取自同一 store 同一字段，
/// Center enqueue 时 scene+scopeId 完全匹配（对齐 im-payload-real-log-over-code-assumption rule §3）
@MainActor
final class GiftEffectSysMsgRouter: MessageRouter {

    static let shared = GiftEffectSysMsgRouter()

    private init() {}

    func route(_ attachType: AttachType,
               payload: [String: Any],
               context: MessageContext) -> Bool {
        // 只 handle sysMsg + syncSysMsg 通道
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

        guard attachType == .liveCallGift else { return false }

        // ext.data 3 层兜底（对齐 NIMChatroomManager v13 payload 解构风格）
        var data: [String: Any] = payload
        if let dataDict = payload["data"] as? [String: Any] {
            data = dataDict
        } else if let dataStr = payload["data"] as? String,
                  let d = dataStr.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            data = parsed
        }

        // 2026-07-10 code-review P0-5 修复：state gate —— idle/ended/failed 期收到
        // syncSysMsg backlog attachType=4 不 intake 也不追加公屏历史（否则通话间残留污染）。
        let callState = CallStore.shared.state
        guard callState != .idle && callState != .ended && callState != .failed else {
            return false
        }

        let scopeId = CallStore.shared.current.callId ?? ""
        let mineYxAccid = SessionStore.shared.user?.yxAccid ?? ""
        GiftEffectIntake.ingest(scene: .call, scopeId: scopeId,
                                 payload: data, mineYxAccid: mineYxAccid)
        // 同步追加到通话公屏历史队列（对齐 H5 messageScroller line 10-13 gift cell）。
        // 独立职责：Intake 走中央大动画 / MicroToast；此路径走左下方消息滚动区。
        CallStore.shared.appendChatGiftFromPayload(data)

        // 返 false：让 SystemMessageRouter / 其他下游继续接收（不独占）——本 router 只做特效侧副作用
        return false
    }
}
