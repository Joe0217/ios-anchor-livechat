import Foundation
import NIMSDK

/// 派对房消息路由（H 里程碑 spec §3.3 / §5）。
///
/// **职责**：从 `PartyRoomChatManager.processIncoming` 接收 custom NIM 消息，
/// 提取 `attachType` 后按 6+9 类业务分发到 `PartyRoomChatManagerDelegate`（由 `PartyStore` 实现）。
///
/// **双轨过渡**（M3 → M5）：
/// - **M3**：`processCustom(_:)` 是主路径，从 `PartyRoomChatManager.processIncoming` 直接调；
///   `MessageRouter.route(_:payload:context:)` 仅做派对房 attachType 通道**短路声明**（标 true 让链路终止，
///   避免下游 router 意外消费派对房消息）但**不**真分发，避免与主路径双重分发。
/// - **M5**：上游 `NIMChatroomManager` 改走 `NIMService.dispatch(context:.liveChatroom)`，
///   届时本 router 的 protocol route 路径才在直播聊天室通道生效；派对房通道由
///   `PartyRoomChatManager` 内部 processCustom 主路径维持，单一来源不重复分发。
///
/// **依赖**：`NIMSDK`（`NIMMessage`）+ `PartyAttachType` + `NIMPayloadDecoder.unwrapDataField`
/// （含 gzip 解压）。主 target only；单测覆盖 `PartyAttachType` raw round-trip + protocol context guard。
@MainActor
final class PartyMessageRouter: MessageRouter {

    /// chat 由 PartyStore 在 onAppear 注入；M3 阶段每个 PartyMessageRouter 与一个 PartyRoomChatManager 1-1 绑定
    weak var chatManager: PartyRoomChatManager?

    /// 业务回调（PartyStore 实现 PartyRoomChatManagerDelegate）
    weak var delegate: PartyRoomChatManagerDelegate?

    // MARK: - M3 主路径：处理 NIMMessage（从 PartyRoomChatManager.processIncoming 调）

    /// 自定义消息分发。提取 `remoteExt.type` / `remoteExt.attachType` → `PartyAttachType` → 业务 handler。
    /// 未识别项打 warning 日志；范围外 attachType 经 `PartyKnownButUnhandledAttachType.codes` 降噪。
    func processCustom(_ m: NIMMessage) {
        guard let chat = chatManager else {
            AppLogger.party.notice("[PartyRouter] chatManager nil, drop custom msg")
            return
        }
        guard let ext = m.remoteExt as? [String: Any] else { return }

        // 兼容两种键名：sapi 数字消息用 type，聊天室 attach 用 attachType
        let raw: Int
        if let v = ext["type"] as? Int { raw = v }
        else if let v = ext["attachType"] as? Int { raw = v }
        else if let s = ext["type"] as? String, let v = Int(s) { raw = v }
        else if let s = ext["attachType"] as? String, let v = Int(s) { raw = v }
        else {
            // 二轮复查 wfpw5v1us（P1-1 加固）：unrecognized 分支触发条件是"schema 异常 / 恶意 NIM 自定义消息"，
            // 输入比 1012 已知 schema 更不可控；若攻击者在 key 名里夹带 PII（如 "userId_123456"）会泄漏。
            // .private 让 Release 包自动遮蔽，dev 期仍可见调试。
            AppLogger.party.notice("[PartyRouter] custom msg missing type field; ext keys=\(Array(ext.keys), privacy: .private)")
            return
        }

        guard let kind = PartyAttachType.from(rawValue: raw) else {
            // 值冲突 / F 期常量 → 仅 debug 级降噪
            if PartyKnownButUnhandledAttachType.codes.contains(raw) {
                AppLogger.party.debug("[PartyRouter] known-but-unhandled attachType=\(raw, privacy: .public)")
            } else {
                AppLogger.party.notice("[PartyRouter] unrecognized attachType=\(raw, privacy: .public)")
            }
            return
        }

        handle(attachType: kind, message: m, ext: ext, chat: chat)
    }

    private func handle(attachType: PartyAttachType,
                        message m: NIMMessage,
                        ext: [String: Any],
                        chat: PartyRoomChatManager) {
        // ext.data 三态识别（安卓确认 §3.0，后端 NetEaseChatRoomServiceImpl.java:301-337）
        let payload = NIMPayloadDecoder.unwrapDataField(from: ext) ?? [:]

        AppLogger.party.info("[PartyRouter] handle \(attachType.rawValue, privacy: .public)")

        switch attachType {
        case .seatUpdate:
            delegate?.partyRoomChat(chat, didReceiveSeatUpdate: payload, raw: m)
        case .seatUpdateList:
            // review 202606260029 P2-7：与 line 49 同源威胁模型——远端可控 key 名可能夹带 PII
            // （如 "userId_123456"），统一 .private 让 Release 包遮蔽，调试期 dev profile 直读。
            AppLogger.party.notice("[PartyRouter] 1012 keys=\(Array(ext.keys), privacy: .private)")
            delegate?.partyRoomChatDidRequireSeatListReload(chat)
        case .prohibitMic:
            delegate?.partyRoomChat(chat, didReceiveProhibitMic: payload, raw: m)
        case .kickedOut:
            handleKickedOut(payload: payload, chat: chat)
        case .updateMedia:
            delegate?.partyRoomChat(chat, didReceiveMediaUpdate: payload, raw: m)
        case .giftCompressed:
            delegate?.partyRoomChat(chat, didReceiveGift: payload, raw: m)
        case .inviteVideoSeat:
            handleVideoSeatInvite(payload: payload, raw: m, chat: chat)
        case .inviteVideoSeatAccept:
            delegate?.partyRoomChat(chat, didReceiveInviteResult: .accepted)
        case .inviteVideoSeatReject:
            delegate?.partyRoomChat(chat, didReceiveInviteResult: .rejected)
        case .inviteVideoSeatTimeout:
            delegate?.partyRoomChat(chat, didReceiveInviteResult: .timeout)
        case .inviteVideoSeatLeave:
            delegate?.partyRoomChat(chat, didReceiveInviteResult: .leave)
        case .inviteVideoSeatOccupied:
            delegate?.partyRoomChat(chat, didReceiveInviteResult: .occupied)
        case .inviteVideoSeatAlreadyOn:
            delegate?.partyRoomChat(chat, didReceiveInviteResult: .alreadyOn)
        case .inviteVideoSeatBroadcast:
            delegate?.partyRoomChat(chat, didReceiveInviteResult: .broadcast)
        case .inviteVideoSeatJoinFailed:
            delegate?.partyRoomChat(chat, didReceiveInviteResult: .joinFailed)
        }
    }

    /// 被踢双字段守护（spec §1.4.4 防误踢）：payload 内 `userId == 自己 && roomId == 当前房` 才认。
    /// 安卓确认 §3.4：1003 payload `{seatIndex, roomId, userId}` 均为 **Number**（不是 String）；
    /// 跨通道归一化用 `PartyValueNormalizer`（HTTP roomId 是 String / NIM payload 是 Number）。
    /// 守护逻辑下沉 `PartyKickedOutGuard.shouldHandle`（C 档单测重构，2026-06-26）。
    private func handleKickedOut(payload: [String: Any], chat: PartyRoomChatManager) {
        let myUserId = SessionStore.shared.user?.userId.map(String.init)
        guard PartyKickedOutGuard.shouldHandle(payload: payload,
                                                myUserId: myUserId,
                                                chatRoomId: chat.roomId) else {
            // review 202606260029 P2-7：payload 远端可控，key 名可能夹带 PII，.private 让 Release 包遮蔽。
            AppLogger.party.notice("[PartyRouter] kickedOut guard failed (myUid=\(myUserId ?? "nil", privacy: .private) keys=\(Array(payload.keys), privacy: .private))")
            return
        }
        delegate?.partyRoomChatDidKickOut(chat)
    }

    private func handleVideoSeatInvite(payload: [String: Any], raw m: NIMMessage, chat: PartyRoomChatManager) {
        // 安卓确认 §3.8 真实字段：
        // {attachType:1040, inviteId(String), roomId(Number), yxRoomId(String),
        //  seatIndex(Number), ownerUserId(发起人id), ownerNick(发起人昵称), ttl(秒,默认30), roomTempId(Number)}
        // ⚠️ 字段名是 ownerUserId/ownerNick，不是 fromUserId/fromNickname
        // 解析+守卫下沉 `PartyVideoSeatInvite.from`（C 档单测重构，2026-06-26）。
        guard let invite = PartyVideoSeatInvite.from(
            payload: payload,
            fallbackRoomId: chat.roomId,
            timestampMs: Int64(m.timestamp * 1000)
        ) else {
            // review 202606260029 P2-7：payload 远端可控，key 名可能夹带 PII，与 line 49 同源 .private。
            AppLogger.party.notice("[PartyRouter] 1040 invite payload missing inviteId/seatIndex; keys=\(Array(payload.keys), privacy: .private)")
            return
        }
        delegate?.partyRoomChat(chat, didReceiveVideoSeatInvite: invite)
    }

    // MARK: - M5 备用路径：MessageRouter protocol

    /// **M3 阶段**：仅声明本 router 处理派对房 attachType（链路短路），**不真分发**——避免与
    /// `processCustom` 主路径双重处理。M5 上游改走 `NIMService.dispatch(.partyChatroom)` 时再启用。
    ///
    /// **M5 后**预期行为：
    /// ```
    /// case .partySeatUpdate / partyKickedOut / partyUpdateMedia / partySeatUpdateList /
    ///      partyProhibitMic / partyGiftCompressed / partyInviteVideoSeat:
    ///     // 走 handle(...) 业务分发；payload 已是 unwrapDataField 后的字典，raw 设为 nil
    ///     return true
    /// ```
    func route(_ attachType: AttachType,
               payload: [String: Any],
               context: MessageContext) -> Bool {
        guard case .partyChatroom = context else { return false }
        switch attachType {
        case .partySeatUpdate, .partyKickedOut, .partyUpdateMedia, .partySeatUpdateList,
             .partyProhibitMic, .partyGiftCompressed, .partyInviteVideoSeat:
            return true
        default:
            return false
        }
    }
}
