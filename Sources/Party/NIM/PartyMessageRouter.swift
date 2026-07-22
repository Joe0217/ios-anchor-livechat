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
            delegate?.partyRoomChatDidRequireSeatListReload(chat, msgTimestampMs: Int64(m.timestamp * 1000))
        case .prohibitMic:
            delegate?.partyRoomChat(chat, didReceiveProhibitMic: payload, raw: m)
        case .privateCallNotify:
            // F 期 1029 派对房私 call 状态通知（spec §4.2 P0-4 双重定义防御）
            // PartyPrivateCallNotify decoder 硬要求 status enum ∈ {calling, ended}；
            // GIFT_DOUBLED 语义（无 status 字段）会 throw dataCorrupted → drop
            AppLogger.party.info("[PartyRouter] 1029 privateCallNotify payloadKeys=\(Array(payload.keys), privacy: .public)")
            do {
                let data = try JSONSerialization.data(withJSONObject: payload)
                let notify = try JSONDecoder().decode(PartyPrivateCallNotify.self, from: data)
                delegate?.partyRoomChat(chat, didReceivePrivateCallNotify: notify, raw: m)
            } catch {
                AppLogger.party.debug("[PartyRouter] 1029 decode failed (likely GIFT_DOUBLED / unknown status) → drop err=\(String(describing: error), privacy: .public)")
            }
        case .kickedOut:
            handleKickedOut(payload: payload, chat: chat)
        case .updateMedia:
            delegate?.partyRoomChat(chat, didReceiveMediaUpdate: payload, raw: m)
        case .musicMainSwitch:
            // H5 session.js 1010：全房总开关变动，关闭时会同时停止本地播放。
            AppLogger.party.info("[PartyRouter] 1010 musicMainSwitch payloadKeys=\(Array(payload.keys), privacy: .public)")
            delegate?.partyRoomChat(chat, didReceiveRoomMusicAvailability: payload, raw: m)
        case .musicSongChange:
            // H5 party.js 1011：直接合并歌曲、播放状态、音量与模式。
            AppLogger.party.info("[PartyRouter] 1011 musicSongChange payloadKeys=\(Array(payload.keys), privacy: .public)")
            delegate?.partyRoomChat(chat, didReceiveMusicUpdate: payload, switchOnly: false, raw: m)
        case .musicSwitchPerUser:
            // H5 party.js 1013：`isEnable` 驱动音乐小组件与管理入口的 ON/OFF 状态。
            AppLogger.party.info("[PartyRouter] 1013 musicSwitch payloadKeys=\(Array(payload.keys), privacy: .public)")
            delegate?.partyRoomChat(chat, didReceiveMusicUpdate: payload, switchOnly: true, raw: m)
        case .giftCompressed:
            let giftCount = (payload["gifts"] as? [[String: Any]])?.count ?? 1
            // 首次真机收礼时据此核对 2049 解压后的字段（特别是 rewardPool / sendUser 身份字段）。
            AppLogger.party.info(
                "[PartyRouter] 2049 gift payloadKeys=\(Array(payload.keys), privacy: .public) giftCount=\(giftCount, privacy: .public)"
            )
            delegate?.partyRoomChat(chat, didReceiveGift: payload, raw: m)
        case .userEnterVehicle:
            // v23（2026-07-13）用户进场座驾动画 attachType=1004：派对房座驾 SVGA/MP4 全屏特效
            delegate?.partyRoomChat(chat, didReceiveEnterAnimation: payload, raw: m)
        case .changeMode:
            // E v2 §1 Room Mode 切模板广播；msgTimestampMs 用于步骤 1 乱序判丢（vs lastRoomTempSwitchAt）。
            // 真机 log 校对字段名（im-payload-real-log-over-code-assumption rule）：
            //   payloadKeys=\(Array(payload.keys)) 期望含 seats / currentSeatIndex / currentUserId / seatOperate / roomTempId
            AppLogger.party.info("[PartyRouter] 1017 changeMode payloadKeys=\(Array(payload.keys), privacy: .public)")
            delegate?.partyRoomChat(chat, didReceiveModeChange: payload, msgTimestampMs: Int64(m.timestamp * 1000))
        case .queueSeatUpdate:
            // E v2 §2 Mic Application 排麦通知；payload 期望 { num, operation, userId }。
            AppLogger.party.info("[PartyRouter] 1018 queueSeatUpdate payloadKeys=\(Array(payload.keys), privacy: .public)")
            delegate?.partyRoomChat(chat, didReceiveQueueSeatUpdate: payload, raw: m)
        case .micApplicationSwitch:
            // E v2 §2 Mic Application 开关广播；payload 期望 { enable: Int }。
            AppLogger.party.info("[PartyRouter] 1021 micApplicationSwitch payloadKeys=\(Array(payload.keys), privacy: .public)")
            delegate?.partyRoomChat(chat, didReceiveMicApplicationSwitch: payload, raw: m)
        case .inviteVideoSeat:
            handleVideoSeatInvite(payload: payload, raw: m, chat: chat)
        case .inviteVideoSeatAccept:
            delegate?.partyRoomChat(chat, didReceiveInviteResult: .init(kind: .accepted, payload: payload))
        case .inviteVideoSeatReject:
            delegate?.partyRoomChat(chat, didReceiveInviteResult: .init(kind: .rejected, payload: payload))
        case .inviteVideoSeatTimeout:
            delegate?.partyRoomChat(chat, didReceiveInviteResult: .init(kind: .timeout, payload: payload))
        case .inviteVideoSeatLeave:
            delegate?.partyRoomChat(chat, didReceiveInviteResult: .init(kind: .leave, payload: payload))
        case .inviteVideoSeatOccupied:
            delegate?.partyRoomChat(chat, didReceiveInviteResult: .init(kind: .occupied, payload: payload))
        case .inviteVideoSeatAlreadyOn:
            delegate?.partyRoomChat(chat, didReceiveInviteResult: .init(kind: .alreadyOn, payload: payload))
        case .inviteVideoSeatBroadcast:
            delegate?.partyRoomChat(chat, didReceiveInviteResult: .init(kind: .broadcast, payload: payload))
        case .inviteVideoSeatJoinFailed:
            delegate?.partyRoomChat(chat, didReceiveInviteResult: .init(kind: .joinFailed, payload: payload))

        // MARK: - v3（2026-07-14）Step 1 新增分派

        case .gameWinNotifyGlobal:
            // 136 全服游戏中奖公屏（session.js 主入口 + party.js 兜底）
            AppLogger.party.info("[PartyRouter] 136 payloadKeys=\(Array(payload.keys), privacy: .public)")
            delegate?.partyRoomChat(chat, didReceiveGameWinGlobal: payload, raw: m)
        case .pkSmallPrize:
            // 138 PK 小奖 / Party 房游戏小奖（字段结构同 136）
            AppLogger.party.info("[PartyRouter] 138 payloadKeys=\(Array(payload.keys), privacy: .public)")
            delegate?.partyRoomChat(chat, didReceivePkSmallPrize: payload, raw: m)
        case .winnerBroadcastGlobal:
            // 140 活动中奖公屏广播（含 worldcup）
            AppLogger.party.info("[PartyRouter] 140 payloadKeys=\(Array(payload.keys), privacy: .public)")
            delegate?.partyRoomChat(chat, didReceiveWinnerBroadcast: payload, raw: m)
        case .authUpdate:
            // 1019 房管变更（仅本人被设/取消，Store 端做 userId==self 校验）
            AppLogger.party.info("[PartyRouter] 1019 payloadKeys=\(Array(payload.keys), privacy: .public)")
            delegate?.partyRoomChat(chat, didReceiveAuthUpdate: payload, raw: m)
        case .roomAnnouncement:
            // 1049 房间通告公屏广播
            AppLogger.party.info("[PartyRouter] 1049 payloadKeys=\(Array(payload.keys), privacy: .public)")
            delegate?.partyRoomChat(chat, didReceiveRoomAnnouncement: payload, raw: m)
        case .luckyNumberDraw:
            // H5 优先取 ext.data，缺失时才回退顶层 ext；兼容对象和 JSON 字符串两种 data 形态。
            let luckyPayload = PartyLuckyNumberPayload.publicMessagePayload(from: ext)
            AppLogger.party.info("[PartyRouter] 1050 payloadKeys=\(Array(luckyPayload.keys), privacy: .public)")
            delegate?.partyRoomChat(chat, didReceiveLuckyNumberDraw: luckyPayload, raw: m)
        case .luckyNumberWin:
            let luckyPayload = PartyLuckyNumberPayload.publicMessagePayload(from: ext)
            AppLogger.party.info("[PartyRouter] 1051 payloadKeys=\(Array(luckyPayload.keys), privacy: .public)")
            delegate?.partyRoomChat(chat, didReceiveLuckyNumberWin: luckyPayload, raw: m)

        // MARK: - 一刀切忽略（老版送礼 / H5 空占位）

        case .giftLegacy:
            // 1007 明文送礼 —— iOS 只信 2049 giftCompressed 双发去重
            return
        case .roomLock, .rejectMicLegacy:
            // H5 空占位 case（H5 用户端也 `break` 不处理），iOS 同步不消费
            return

        // F 期房主管理批消费（2026-07-17）
        case .platformAdminChange:
            // 1024 平台超管任免广播。payload 结构待真机 preflight（agent-recon-field-names-unverified rule）——
            // iOS 主播端只关心"自己被任免"场景，但 roomInfo.isPlatformAdmin 属账号级字段（enterRoom
            // 已经填充），受任免影响的更多是"某观众显示超管装饰"这类跨端 UI，iOS 主播端不承接。
            // 保留独立 case 便于后续接入 log + 观察 payload；不改任何 state 避免误设。
            AppLogger.party.info("[PartyRouter] 1024 platformAdminChange payloadKeys=\(Array(payload.keys), privacy: .public)")
        case .roomBgUpdate:
            // 1025 房间背景更新广播。所有观众端应刷新背景。payload 字段名待真机 preflight —
            // iOS 稳妥策略：不依赖 payload 字段，直接触发 delegate → PartyStore.loadCurrentRoomBackground()
            // 全量重拉 getRoomBgImage 接口，与房主端 setBgImages 后的状态一致。
            AppLogger.party.info("[PartyRouter] 1025 roomBgUpdate payloadKeys=\(Array(payload.keys), privacy: .public)")
            delegate?.partyRoomChatDidRequireRoomBgReload(chat, expired: false)
        case .roomBgExpire:
            // 1026 房间背景过期广播（时限背景到期回默认）。iOS 清 currentRoomBackground → UI 层
            // fallback DEFAULT_BG（对齐 PartyRoomBackgroundView 三层 fallback 语义）。
            AppLogger.party.info("[PartyRouter] 1026 roomBgExpire payloadKeys=\(Array(payload.keys), privacy: .public)")
            delegate?.partyRoomChatDidRequireRoomBgReload(chat, expired: true)

        // MARK: - F 里程碑（2026-07-17）表情面板 IM 分发

        case .emojiPlay, .emojiStatic:
            // 对齐 H5 `party.js:744-761` handleAttachType case -10/-11 分支：
            // 1. 从 ext.data 派生 EmojiPayload（缺字段 drop）
            // 2. self-echo skip：云信 chatroom 会 push 自己发的消息回来（H5 明示"self-echo skip 已踩坑"）
            // 3. 派发到 Store 队列 → 麦位 SVGA player 消费
            AppLogger.party.info("[PartyRouter] \(attachType.rawValue, privacy: .public) payloadKeys=\(Array(payload.keys), privacy: .public)")
            guard let emojiPayload = PartyEmojiPayload.from(payload: payload) else {
                AppLogger.party.notice("[PartyRouter] \(attachType.rawValue, privacy: .public) emoji payload missing required fields (emojiId/playUrl/sendUserId); drop")
                return
            }
            // self-echo skip：sendUserId == 自己 → 已由本地发送时 append 过（sendEmoji 本地立即入队）· 避免双入队
            if let myUserId = SessionStore.shared.user?.userId.map(String.init),
               emojiPayload.sendUserId == myUserId {
                AppLogger.party.debug("[PartyRouter] \(attachType.rawValue, privacy: .public) self-echo skip uid=\(myUserId, privacy: .public)")
                return
            }
            delegate?.partyRoomChat(chat, didReceiveEmoji: emojiPayload, raw: m)

        // MARK: - 占位群组（F 期功能未落 / Android 独有不实装）

        case .roomCloseOrWhitelist,
             .auditGuardWarning,
             .diamondGiftSend, .diamondGiftGrab, .diamondGiftSplit, .diamondGiftSettle,
             .luckyNumberPersonalDialog:
            AppLogger.party.debug("[PartyRouter] placeholder attachType=\(attachType.rawValue, privacy: .public)")
            return

        // F-1a Task 11 · PartyBattle 1100-1112 全号段分流到独立 router
        case .battleSelectingStart, .battleTeamMemberChange, .battleApplyReceived,
             .battleRunningStart, .battleLeaderboardUpdate, .battleCrownHolderUpdate,
             .battleEnd, .battleBroadcast, .battleCooldownEnd,
             .battleHeartbeat, .battleGiftNotify, .battleForceEndConfirm, .battleApplyPendingNotice:
            _ = PartyBattleMessageRouter.dispatch(attachType: attachType, payload: payload)
            return
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

    // MARK: - E v2：本地系统消息投递（Room Mode 切换 / Mic Application 开关公屏系统消息）
    // v3（2026-07-15）：迁移到 `.partyModeSwitch` unified variant 4 类 kind + `.announcement`
    // 通过 [`PartyPublicChatAdapter`](../Chat/PartyPublicChatAdapter.swift) 生成 message

    /// 1017 切模板系统消息（kind: .mode）
    func postSystemMode(_ text: String) {
        guard let chat = chatManager else {
            AppLogger.party.notice("[PartyRouter] postSystemMode skip: chatManager nil")
            return
        }
        chat.appendMessage(PartyPublicChatAdapter.systemMode(text: text))
    }

    /// 1021 排麦开关系统消息（kind: .application）
    func postSystemApplication(_ text: String) {
        guard let chat = chatManager else {
            AppLogger.party.notice("[PartyRouter] postSystemApplication skip: chatManager nil")
            return
        }
        chat.appendMessage(PartyPublicChatAdapter.systemApplication(text: text))
    }

    /// 1019 房管变更系统消息（kind: .authUpdate；仅本人被设/取消）
    func postSystemAuthUpdate(_ text: String) {
        guard let chat = chatManager else {
            AppLogger.party.notice("[PartyRouter] postSystemAuthUpdate skip: chatManager nil")
            return
        }
        chat.appendMessage(PartyPublicChatAdapter.systemAuthUpdate(text: text))
    }

    /// 1047 视频位邀请接受系统消息（kind: .videoSeatInvite）
    func postSystemVideoSeatInvite(_ text: String) {
        guard let chat = chatManager else {
            AppLogger.party.notice("[PartyRouter] postSystemVideoSeatInvite skip: chatManager nil")
            return
        }
        chat.appendMessage(PartyPublicChatAdapter.systemVideoSeatInvite(text: text))
    }

    /// 1049 房间通告公屏（`.announcement(kind: .partyRoom)`）
    func postAnnouncement(_ text: String) {
        guard let chat = chatManager else {
            AppLogger.party.notice("[PartyRouter] postAnnouncement skip: chatManager nil")
            return
        }
        chat.appendMessage(PartyPublicChatAdapter.announcement(text: text))
    }

    /// Party 房 Battle Team PK 系统消息（`.partyBattle(kind:)` unified variant · 4 kind 独立视觉）
    /// 对齐 H5 chat-list.vue :333-392 · PK icon + 半透黑底 + #FFE600 黄色高亮
    func postSystemBattle(kind: PartyBattleSystemKind, text: String, highlight: String? = nil) {
        guard let chat = chatManager else {
            AppLogger.party.notice("[PartyRouter] postSystemBattle skip: chatManager nil")
            return
        }
        chat.appendMessage(PartyPublicChatAdapter.battleSystem(kind: kind, text: text, highlight: highlight))
    }

    /// **Deprecated（v3）**：旧调用点入口。默认走 `.partyModeSwitch(kind: .mode)`。
    /// 现有 caller（handleRoomModeChanged @ L928）应改调 `postSystemMode`。
    @available(*, deprecated, renamed: "postSystemMode")
    func postSystemMessage(_ text: String) {
        postSystemMode(text)
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
        if case .partyLuckyNumberPersonalDialog = attachType {
            switch context {
            case .sysMsg, .syncSysMsg:
                guard let chat = chatManager else { return false }
                delegate?.partyRoomChat(chat, didReceiveLuckyNumberPersonalWin: payload)
                return true
            default:
                break
            }
        }
        guard case .partyChatroom = context else { return false }
        switch attachType {
        case .partySeatUpdate, .partyKickedOut, .partyUpdateMedia, .partySeatUpdateList,
             .partyProhibitMic, .partyPrivateCallNotify, .partyGiftCompressed, .partyInviteVideoSeat:
            return true
        default:
            return false
        }
    }
}
