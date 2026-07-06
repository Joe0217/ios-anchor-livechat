import Foundation

/// IM 场景过滤的**纯决策层**：根据当前场景 + attachType + 通道，决定 sysMsg 是否分发。
///
/// 拆出纯函数让 `HilyTests`（logic test bundle，不 link 主 app）可零 SDK 依赖断言全 case；
/// 副作用层 `IMSceneGate` 持有运行时状态（active / graceUntil / pending exit task）+ wiring。
///
/// **设计核心**（详见 docs/plan/IM场景过滤-spec-* 路线图追踪 2026-06-26 条目）：
/// 1. **业务正确性 > 性能**：必收清单 + grace period 双保险
/// 2. **chatroom 通道直接放行**：roomId 守卫已剔跨房，无需 gate 二次过滤
/// 3. **必收清单永不 drop**：forceEndLive / banned / followIncrement / anchorAuditChange
///    — 在 weak store nil 时执行 noop 不副作用，但保留路径保业务不丢
/// 4. **登录/重连 grace**：connectionState .connecting → .connected 转变后 10s 内全放行，
///    覆盖离线 backlog（backlog 是过去事件，不能按当前场景过滤）
/// 5. **call exit grace 8s**：state → .idle 后延迟 8s 才真退场景，
///    接收挂断后尾消息（如延迟到达的 callRechargeReward）
///
/// **通道矩阵**：
/// - liveChatroom / partyChatroom / p2p → 永远放行（chatroom 由 roomId 守卫；p2p 暂未实施）
/// - syncSysMsg → 永远放行（backlog 不过滤）
/// - sysMsg → grace 内放行；否则按 mustReceive + matchesActive
enum IMSceneFilter {

    /// 当前活跃场景集合。OptionSet 支持组合（直播私 call = .live + .call）。
    ///
    /// 不引入 `.pk`：PK 消息走 liveChatroom 通道不走 sysMsg，与本过滤层无关。
    /// 其他"中间页"（Profile / Settings / Moments / LiveList 等）统一 = `[]`（idle），
    /// 因为这些页面不订阅业务态 sysMsg。
    struct ActiveScenes: OptionSet, Equatable {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }

        static let live  = ActiveScenes(rawValue: 1 << 0)
        static let call  = ActiveScenes(rawValue: 1 << 1)
        static let party = ActiveScenes(rawValue: 1 << 2)
    }

    /// 必收清单：任何场景永不 drop。
    ///
    /// 选取原则：
    /// - **永久状态变化**：followIncrement / anchorAuditChange — 写入 SessionStore 单例
    /// - **强制下播业务约束**：forceEndLive / banned — weak liveStore nil 时 noop，
    ///   非 nil（用户在直播但因某原因 active.live 未及时同步）时确保不丢
    ///
    /// 注：1004 onKickout / 1005 onAutoLoginFailed 不走 dispatch（NotificationCenter 直接广播），
    /// 不在本拦截路径，无需列入。
    static let mustReceive: Set<String> = [
        AttachType.forceEndLive.raw,        // 44
        AttachType.banned.raw,              // 62
        AttachType.followIncrement.raw,     // -4
        AttachType.anchorAuditChange.raw,   // 58
        AttachType.forcedOffline.raw,       // 37 服务端主动踢下线（触发 hasExceededCallLimit）
    ]

    /// 决策入口。任意输入安全，缺字段走兜底（不抛错、不 crash）。
    ///
    /// - Parameters:
    ///   - attachType: 解码后的 attachType
    ///   - context: 消息通道（决定是否经过本过滤层）
    ///   - active: 当前活跃场景集合
    ///   - graceUntil: backlog grace 窗口结束时间（Date.distantPast 表示未启用）
    ///   - now: 当前时刻（注入便于单测）
    /// - Returns: `true` 放行 → router 链路分发；`false` drop → 仅 debug 日志
    static func allows(
        attachType: AttachType,
        context: MessageContext,
        active: ActiveScenes,
        graceUntil: Date,
        now: Date
    ) -> Bool {
        // 通道判定：仅 sysMsg 通过本过滤层
        switch context {
        case .sysMsg:
            break  // 进入下方完整判定
        case .liveChatroom, .partyChatroom, .p2p, .syncSysMsg:
            return true
        }

        // backlog grace 窗口（登录/重连后 N 秒内全放行）
        if now < graceUntil { return true }

        // 必收清单
        if mustReceive.contains(attachType.raw) { return true }

        // 按 attachType 类别 + active 判定
        return matchesActive(attachType, active: active)
    }

    /// 按 attachType 业务类别匹配 active 场景。
    ///
    /// **穷举式 switch（无 default）**：AttachType 加新 case 时编译期强制开发者在本处声明意图，
    /// 避免新 case 被默默放行/drop（与 SystemMessageRouteDecision 同模式）。
    private static func matchesActive(_ at: AttachType, active: ActiveScenes) -> Bool {
        switch at {

        // ===== 直播单独相关：仅 .live active 时收 =====
        case .complianceWarning,            // 61 合规警告 toast
             .boostingExposure,             // 63 进折扣池
             .boostingExposureExit,         // 64 退折扣池
             .liveAnnouncement,             // 195 直播间公告
             .privateCallSwitchChange,      // 52 私 call 开关
             .liveGiftRankUpdate,           // 50 直播间排行 + 热度
             .rankUpdateOnly,               // 56 排行（不含热度）
             .hotScoreUpdate,               // 71 热度衰减
             .enterRoomAnimation,           // 80 进场动画
             .privateCallEnterAnimation,    // 83 私 call 进场座驾
             .wishlistFirst,                // 250 心愿单首次贡献
             .wishlistTop1,                 // 251 心愿单 TOP1 变更
             .wishlistPoolDone,             // 252 心愿单整池完成
             .wishlistGiftDone,             // 253 心愿单单礼物达成
             .diamondBoxWarm,               // 1030 钻石福袋发包
             .diamondBoxOpen,               // 1031 钻石福袋开抢
             .diamondBoxClaim,              // 1032 钻石福袋瓜分
             .diamondBoxSettle:             // 1033 钻石福袋结算
            return active.contains(.live)

        // ===== 通话单独相关：仅 .call active 时收 =====
        case .callRemoteMessage,            // -1 远端字幕 + chatBubble
             .callPayWaitState,             // -6 通话充值等待
             .callIncomePerMinute,          // 15 每分钟预估收入
             .callGiftIncome,               // 18 通话礼物预估收入
             .callRechargeReward,           // 90 通话充值钻石奖励
             .callCancel,                   // -3 通话取消（RTM 主路径已处理，sysMsg 仅日志）
             .liveCallGift,                 // 4 通话内对方送礼
             .giftRequestRejected:          // 16 主播索礼被拒
            return active.contains(.call)

        // ===== 礼物送达跨 live/call：直播态收礼 / 通话内收礼都可能 =====
        case .sendGift:                     // 1 / 'SEND_GIFT'
            return active.contains(.live) || active.contains(.call)

        // ===== PK / 派对房：spec 锁定不走 sysMsg，sysMsg 路径直接 drop =====
        // （它们的真实通道是 liveChatroom / partyChatroom，由 router context guard 处理）
        case .pkInvite, .pkScoreUpdate, .pkInviteAck, .pkStatusBundle,
             .pkMuteBroadcast, .pkChatNotice,
             .partySeatUpdate, .partyKickedOut, .partyUpdateMedia,
             .partySeatUpdateList, .partyProhibitMic, .partyGiftCompressed,
             .partyInviteVideoSeat:
            return false

        // ===== 全局 toast / J 期：任何场景都可能弹（活动 / 猜拳 / 任务奖励 / CP 排行）=====
        case .activityWinnerPublic, .guessGameWinner, .activityApproved,
             .activityRemind30Min, .anchorTaskReward,
             .userRechargeSuccess, .userBindAfterRecharged, .userBindAfterNotRecharged,
             .cpRankReward, .cpRankPreEnd, .activeTycoonEnter, .agentRecharge:
            return true

        // ===== 兜底 =====
        case .knownButUnhandled, .unknown:
            return false

        // ===== mustReceive 已早返 true，此处列出避免 exhaustive switch 漏 case =====
        case .forceEndLive, .banned, .followIncrement, .anchorAuditChange, .forcedOffline:
            return true
        }
    }
}
