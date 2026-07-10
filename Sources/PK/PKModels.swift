import Foundation

// MARK: - 主态状态机（spec §2.2 九态枚举）

/// PK 主态状态机；与 LiveStore.callState 联动（spec §2.4）：
/// idle/failed → callState=0；matching/inviting/invited → 2；inPK/punishing → 3；
/// starting/endingPK 是瞬时态由 inPK/punishing 自然覆盖。
enum PKStateMain: String, Equatable {
    case idle           // 直播态、未发起 PK
    case matching       // 随机匹配中（QUICK 15s + RETRY 5min）
    case inviting       // 已发出 PK 邀请，60s 倒计时
    case invited        // 收到 PK 邀请，60s 倒计时
    case starting       // 匹配成功/邀请接受 → 调 joinPk 拿 pkId / endTime
    case inPK           // PK 进行中
    case punishing      // PK 结束惩罚态 120s
    case endingPK       // 主动中断/正常结束发起接口期间（瞬时）
    case failed         // 异常态（pkStatus=-1 / API 业务码 / 网络抖动）
}

/// PK 类型（joinPk 入参）。
enum PKType: Int, Codable {
    case random = 1
    case invite = 2
}

/// PK 邀请类型（handleInvite 入参）。
enum PKInviteHandle: Int {
    case accept = 1
    case reject = 2
    case timeout = 3         // 60s 本地倒计时由本端主动上报
    case cancel = 4
}

/// PK 结束分流（endPk / endPunishing 入参 `isActiveDisconnect`）。
enum PKDisconnectType: Int {
    case normal = 1           // 倒计时归零自然结束
    case activeInterrupt = 2  // UI 主动中断
    case abnormal = 3         // 异常断线
}

/// 惩罚态 disconnectFromStatus（endPunishing 入参）。
enum PKPunishFromStatus: Int {
    case inPK = 7
    case punishing = 8
}

// MARK: - 请求/响应模型

/// 主动方发起邀请记录（PKStore.invitedAnchors[anchorUserId]）。
/// 对齐 H5 livePk.js:452 `inviteData.invitedList.push({userId, inviteTime, duration, nickname, avatar})`。
struct PKInvitedItem: Equatable {
    let anchorUserId: Int
    let inviteTime: Date
    let duration: Int               // 该条邀请的 PK 时长（秒）
    let nickname: String?
    let avatar: String?
}

/// 匹配成功上下文 / 邀请被接受时拿到的对手信息（startPkMatch / pkStatus=10 / handleInviteAccepted）。
struct PKMatchResult: Codable, Equatable {
    let userId: Int
    let nickname: String?
    let avatar: String?
    let countryId: String?
    let agoraChannelId: String?
}

/// joinPk 响应（spec §1.4 关键字段）。
///
/// ⚠️ **endTime 字段行为对齐 H5**（livePk.js:685 实证）：H5 后端实际不下发 endTime，
/// H5 本地用 `Date.now() + pkDuration * 1000` 毫秒戳自算。iOS 同步此行为：PKStore 拿到响应后
/// 用 `Date() + duration` 自算 endTime，**不依赖**本字段。字段保留可选解码兼容性，后端若下发也能拿到。
/// R3 风险通过 H5 源码消解，无需后端联调单位（毫秒/秒）问题。
struct PKJoinResponse: Codable, Equatable {
    let pkId: String
    let nickname: String?
    let avatar: String?
    let yxAccId: String?
    let countryId: String?
    /// 兼容字段，PKStore 不依赖（见 type 注释）。
    let endTime: Int64?
    /// 后端有时同 joinPk 一并返回 pkDuration；缺字段时取调用方传入值。
    let pkDuration: Int?
}

/// attachType=98 PK 实时分数 + Top3 推送（spec §5.2，真机校验后修订）。
///
/// **后端真实 payload 双字段共存**（2026-06-24 真机抓包）：
/// - `top3User` / `oppositeTop3User` → `[String]` 头像 URL 数组（旧字段，老版本兼容）
/// - `top3Users` / `oppositeTop3Users` → `[PKTopUser]` 含 `userId` + `icon` 的对象数组（新字段，主用）
struct PKScoreUpdate: Codable, Equatable {
    let pkCounter: Int?
    let oppositePkCounter: Int?
    let top3User: [String]?
    let oppositeTop3User: [String]?
    let top3Users: [PKTopUser]?
    let oppositeTop3Users: [PKTopUser]?
}

/// PK Top3 / 全榜单条目。字段来源混合：
/// - attachType=98 实时 push 仅含 `userId`(Int) + `icon`(String)
/// - getPkTop3RankList REST 接口含 `userId` + `nickName`(驼峰非对称) + `avatar` + `value`
/// 字段全可选，按业务场景按需取（icon / avatar 二选一显示头像）。
struct PKTopUser: Codable, Equatable {
    let userId: Int?
    let icon: String?
    let nickName: String?
    let avatar: String?
    let value: Int?

    /// UI 显示头像统一入口：优先 icon（98 push），fallback avatar（REST 接口）
    var displayAvatar: String? { icon ?? avatar }
}

/// attachType=97 收到 PK 邀请（spec §5.2）。
struct PKInviteInfo: Codable, Equatable {
    let userId: Int
    let nickname: String?
    /// 邀请方头像 URL（后端可能下发，spec 类型声明不完整；参 [ios-decode-userid-compat] 精神：H5 类型声明不可信）
    let avatar: String?
    let countryId: String?
    let agoraChannelId: String?
    let pkDuration: Int
}

/// attachType=99 邀请状态变更（spec §5.2）。
struct PKInviteAck: Codable, Equatable {
    let userId: Int?
    let nickname: String?
    let inviteStatus: Int             // 1接受 / 2拒绝 / 3超时（本地） / 4取消
    let pkDuration: Int?
    let agoraChannelId: String?       // inviteStatus=1 时才有
    let countryId: String?
}

/// attachType=100 PK 状态束（spec §5.2；按 data.pkStatus 子分发 7/8/9/10/-1）。
struct PKStatusBundle: Codable, Equatable {
    let pkStatus: Int                 // 7客态进PK / 8进惩罚 / 9对方结束 / 10匹配成功 / -1异常断线
    let userId: Int?
    let nickname: String?
    let avatar: String?
    let countryId: String?
    let agoraChannelId: String?
    let result: Int?                  // 1胜 / 2负 / 3平（pkStatus=8 时）
    let pkCounter: Int?
    let oppositePkCounter: Int?
    let reason: Int?                  // 0normal / 1interrupt / 2timeout
    let isActiveInterrupt: Bool?
}

/// getPkStatus 响应（spec §1.4：'INPK' / 'PUNISHING' / null）。
enum PKRemoteStatus: String, Codable {
    case inPK = "INPK"
    case punishing = "PUNISHING"
}

// MARK: - 推荐主播列表（G §6 / spec §1.2 反悔扩展）

/// 推荐主播条目（getRecommendAnchorList 返回）。
/// 字段对齐 H5 pkAnchorListItem.vue + usePkInviteButton.js：
/// - `userId` 必返；`nickname` / `avatar` / `icon` 二选一；`countryId` 国家码；
/// - `pkStatus` 关键按钮态分流（0忙 / 1可邀 / 2等待同意 / 3 PK中）。
struct PKRecommendAnchor: Codable, Equatable, Identifiable {
    let userId: Int
    let nickname: String?
    let avatar: String?
    let icon: String?
    let countryId: String?
    /// 0不可邀（离线/忙）/ 1可邀 / 2 等待同意（已被别人邀）/ 3 PK 中（H5 usePkInviteButton 同语义）
    let pkStatus: Int?

    var id: Int { userId }
    /// UI 显示头像：优先 avatar，fallback icon（对齐 H5 `anchor.avatar || anchor.icon`）
    var displayAvatar: String? { avatar ?? icon }
}

/// getRecommendAnchorList 分页响应解码包装。
/// 后端可能返回 `{list: [...], totalCount: ...}` 或裸数组——本结构兼容前者，裸数组用 `PKRecommendListPagedResponse.tryDecode`。
struct PKRecommendListPagedResponse: Codable {
    let list: [PKRecommendAnchor]?
    let records: [PKRecommendAnchor]?
    let data: [PKRecommendAnchor]?

    var items: [PKRecommendAnchor] { list ?? records ?? data ?? [] }
}
