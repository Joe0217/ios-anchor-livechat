import Foundation

// MARK: - 当前通话信息（对应 H5 myCall.currentCallInfo）
//
// 单一数据源：CallStore 持有一份，整轮通话生命周期内更新；通话结束后归档到 lastCallInfo
// 给 callOver/callRate 上报使用。字段命名沿用 H5 含义以便对照。
struct CurrentCallInfo {
    /// 通话来源（C 仅 direct）
    var frontGameType: CallFrontGameType = .direct
    /// 主被叫角色
    var inOrOut: InOrOut = .out
    /// 服务端分配的频道 ID（既是 RTC channelId 也是 createCall 返回的 channelId）。
    /// 主叫：createCall 返回；被叫：从 H5 CallMessage.fromRoomId 读出。
    /// **命名一致性**：业务/接口层叫 `channelId`，RTM 协议字段叫 `fromRoomId`，二者指代同一对象。
    var channelId: String = ""
    /// 通话唯一 ID（UUID）。主叫端 callOut 时生成；被叫从 CallMessage.callId 读出
    var callId: String = ""
    /// 远端用户 userId（数字）
    var remoteUserId: Int = 0
    /// 远端云信账号（NIM P2P 辅助通道用）
    var remoteYxAccid: String = ""
    /// 远端基本资料（来自 joinCall）
    var remoteNickname: String = ""
    var remoteIcon: String = ""
    /// 远端头像框 URL（joinCall 返回 headFrame；H5 g-waitingCall 佩戴场景显示）。
    /// **iOS 局限**：H5 支持 SVGA 动画头像框（`.svga` 后缀），iOS 侧暂只渲染静态图（PNG/WebP）；
    /// 服务端下发 SVGA 时 CachedAsyncImage 加载失败静默不显示，J 里程碑接入 SVGA 后续支持。
    var remoteHeadFrame: String = ""
    var remoteAge: Int = 0
    var remoteCountryCode: String = ""
    var remoteVideoPrice: Int = 0
    /// 计时锚点（毫秒时间戳）
    var callStartTime: TimeInterval = 0     // 拨出/收到呼叫的时刻
    var callConnectTime: TimeInterval = 0   // RTC 已建链的时刻
    /// 挂断原因（任一方触发 hangup 后写入，调 callOver 时上报）
    var hangupReason: CallOverReason?
    /// 通话内统计（H 里程碑挂入；C 仅占位）
    var callIncome: Int = 0
    var callGiftIncome: Int = 0

    enum InOrOut { case `in`, out }

    /// remoteUserId 的字符串形式（RTM publish channelName 必须用 String）
    var remoteUserIdString: String { String(remoteUserId) }

    /// 已建链时长（秒）；未接通返回 0
    var connectedDuration: Int {
        guard callConnectTime > 0 else { return 0 }
        let nowMs = Date().timeIntervalSince1970 * 1000
        return max(0, Int((nowMs - callConnectTime) / 1000))
    }

    /// 主叫拨出累计时长（秒）；未拨出返回 0
    var sinceStartDuration: Int {
        guard callStartTime > 0 else { return 0 }
        let nowMs = Date().timeIntervalSince1970 * 1000
        return max(0, Int((nowMs - callStartTime) / 1000))
    }
}

// MARK: - RTM 信令消息 ICallMessage（与声网 CallAPI 官方协议严格对齐）
//
// 字段命名遵循 H5 callApi/types/index.ts:351 ICallMessage 接口（字段大小写故意混用是 SDK 历史包袱，
// 不能改）：
//   message_action / message_version / message_timestamp 用 snake_case；
//   callId / fromUserId / remoteUserId / fromRoomId 用 camelCase。
//
// 三个关键字段定义：
// - callId      —— 主叫端 UUID 生成，整轮通话共享；H5 CallMessage.encode 时会强制塞入，
//                  被叫存下来用于后续 reply。
// - fromRoomId  —— 主叫 RTC channelId。被叫据此 join 同一频道（不是 RTM 的 channelName）。
// - fromUserId / remoteUserId —— **number 不是 string**，必须用 Int。
//
// 拒接 / 取消时的可选字段 rejectReason / rejectByInternal / cancelCallByInternal 留位，
// 我端发送时不传（声网 CallAPI 内部用于区分自动拒接 vs 用户拒接，C 不做精细分类）。
struct CallMessage: Codable {
    let messageAction: Int                  // 必填 — 0/1/2/3/4/10
    let fromUserId: Int                     // 必填 — 主叫端 userId
    let remoteUserId: Int                   // 必填 — 被叫端 userId
    let callId: String                      // 必填 — 一通通话的 UUID
    /// 主叫 RTC channelId。**只有 VideoCall 带**（被叫据此 join）；其余 action 不带。
    let fromRoomId: String?
    let messageVersion: String?             // CryptoJS encode 自动加，对端可能不传
    let messageTimestamp: Int64?            // 同上
    /// 仅 Reject 携带
    let rejectReason: String?
    let rejectByInternal: Int?              // 0=External(用户操作) / 1=Internal(SDK 自动)
    /// 仅 Cancel 携带（0/1 同上）
    let cancelCallByInternal: Int?

    enum CodingKeys: String, CodingKey {
        case messageAction       = "message_action"
        case fromUserId
        case remoteUserId
        case callId
        case fromRoomId
        case messageVersion      = "message_version"
        case messageTimestamp    = "message_timestamp"
        case rejectReason
        case rejectByInternal
        case cancelCallByInternal
    }

    var action: CallAction? { CallAction(rawValue: messageAction) }

    /// 通用构造函数。各 action 仅传必要字段，其余保持 nil；Swift JSONEncoder 默认会
    /// 把 .none Optional 跳过（不输出 null），与 H5 实际发送字段一致。
    init(action: CallAction,
         fromUserId: Int,
         remoteUserId: Int,
         callId: String,
         fromRoomId: String? = nil,
         rejectReason: String? = nil,
         rejectByInternal: Int? = nil,
         cancelCallByInternal: Int? = nil) {
        self.messageAction = action.rawValue
        self.fromUserId = fromUserId
        self.remoteUserId = remoteUserId
        self.callId = callId
        self.fromRoomId = fromRoomId
        self.messageVersion = "1.0"
        self.messageTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
        self.rejectReason = rejectReason
        self.rejectByInternal = rejectByInternal
        self.cancelCallByInternal = cancelCallByInternal
    }
}

// MARK: - 接口响应模型

/// POST /api/call/record/v2/createCall 解密后的 result
struct CreateCallResult: Codable {
    let channelId: String?
    let yxAccid: String?
    let videoPrice: Int?
    let countryCode: String?
    let nickname: String?
    let age: Int?
    let icon: String?
    let userType: Int?
    let followed: Int?
    let levelName: String?
}

/// POST /api/agora/live/channelUserCount 解密后的 result（DM-20260616-003）
/// isNormal: true = 后端存在该 channelId 的通话记录（通话正常）；false = 异常（黑屏空房间）
struct ChannelUserCountResult: Codable {
    let isNormal: Bool?
}

/// POST /api/call/record/v2/joinCall 解密后的 result
struct JoinCallResult: Codable {
    let channelId: String?
    let userId: Int?
    let yxAccid: String?
    let icon: String?
    let nickname: String?
    let countryCode: String?
    let age: Int?
    let videoPrice: Int?
    let userType: Int?
    let followed: Int?
    let levelName: String?
    let headFrame: String?
    /// L 里程碑：通话来源标记。'matchV4' → Match 命中；nil / 'liveCall' / 其他 → 非 Match 来源。
    /// MatchStore 通过 CallStore.$lastJoinCallSource 观察此字段决定 matchState 迁移。
    let source: String?
}
