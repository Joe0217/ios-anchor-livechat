import Foundation

// MARK: - 通话状态机（单层，合并 H5 双层 CallStateType + callGameStatus）
//
// 设计取舍：H5 用 CallStateType（SDK 6 态）+ CALL_GAME_STATUS_NUMBER（业务并发态）两层叠加，
// 是因为 RTM 弱网下 SDK 状态可能滞后。iOS 采纳安卓单层 + reason 分流方案。
//
// 注：H5/安卓的状态码（0/1/2/3/4/10）作为对端互通的 SDK 枚举留在 CallAction 那侧，
// 这里 CallState 是 iOS 业务层封装，命名按 Swift 风格。
enum CallState: String {
    case idle           // 空闲
    case prepared       // 已准备（信令通道已就绪，等下一动作）
    case calling        // 呼叫中（主叫等接听 / 被叫等用户操作）
    case connecting     // 连接中（双方已确认接通，RTC join 中）
    case connected      // 通话中（RTC 已建链）
    case ended          // 已结束（正常挂断）
    case failed         // 失败
}

// MARK: - RTM 六类 CallAction（对端互通协议，与 H5/安卓字典必须一致）
//
// 对应 H5 CallApi SDK 内置的 ICallMessage type 枚举。Web 主播端是声网 CallAPI 帮忙封装的，
// iOS 这边自己组装：业务层往 RTM 发 CallMessage JSON，对端解析后驱动自家状态机。
enum CallAction: Int, Codable {
    case videoCall  = 0   // 主叫发起视频呼叫
    case cancel     = 1   // 主叫取消呼叫
    case accept     = 2   // 被叫接受
    case reject     = 3   // 被叫拒绝
    case hangup     = 4   // 任一方挂断
    case audioCall  = 10  // 音频呼叫（iOS 不接入，C 里程碑锁定仅视频）
}

// MARK: - CallStateReason（状态切换原因，用于分流）
//
// 类比 H5 CallStateReason / 安卓 onCallStateChanged reason。iOS 自定义子集，
// 按 happy path + 关键异常路径取，避免一开始就把 SDK 内部所有枚举搬过来。
enum CallStateReason: String {
    case none
    case localVideoCall       // 本地发起视频呼叫
    case remoteVideoCall      // 远端发起视频呼叫
    case localAccept          // 本地接受
    case remoteAccept         // 远端接受
    case localReject          // 本地拒绝
    case remoteRejected       // 远端拒绝
    case localCancel          // 本地取消
    case remoteCancel         // 远端取消
    case localHangup          // 本地挂断
    case remoteHangup         // 远端挂断
    case callingTimeout       // 呼叫超时（主叫 30s 内对端无响应）
    case remoteCallBusy       // 远端忙线
    case messageFailed        // 信令发送失败
    case rtcJoinFailed        // RTC 建链失败
    case kickedOut            // 被踢出（RTM UID_BANNED 等）
}

// MARK: - CallOverReason（H5 CALL_OVER_REASON_NUMBER 1-11，调 /callOver 必须传）
//
// 端侧主动产生的：1 本地挂断 / 2 远端挂断 / 9 用户被踢 / 11 并发取消。
// 后端推送被动产生的：3/5/6/7/8（余额/扣费/弱网）。4 由空房间检测倒计时到期主动上报，
// 以对齐 H5 `systemAbnormal` 自动挂断；其余仍由后端经 NIM 推送或 SDK 错误码反推。
enum CallOverReason: Int {
    case localHangUp                       = 1
    case remoteHangUp                      = 2
    case userBalanceNotEnough              = 3
    case systemHeartBeatFail               = 4
    case systemDeductionBalanceNotEnough   = 5
    case userWeakNetwork                   = 6
    case anchorWeakNetwork                 = 7
    case systemDeductionFail               = 8
    case userKickedOut                     = 9
    case beginCallError                    = 10
    case userConcurrentCancel              = 11
}

// MARK: - NIM 辅助信令 attachType=-3 子类型（H5 CALL_NIM_TYPE_NUMBER，注意是字符串）
//
// 与 RTM 信令并行的兜底通道。H5 message.js 消费 0/1/2/3，useCallApi 接通后还会发送 4。
// RTM 是状态机真值；NIM 仅作弱网辅助通知，不能直接驱动状态迁移，避免双通道重复收尾。
enum CallNimType: String {
    case online    = "0"   // 对端 IM 在线探测
    case reject    = "1"   // 远端拒绝（被叫→主叫）
    case cancel    = "2"   // 远端取消（主叫→被叫）
    case hangUp    = "3"   // 远端挂断
    case connected = "4"   // 远端已接通
}

// MARK: - 通话来源（H5 CALL_FRONT_GAME_TYPE_NUMBER + 安卓 callerType 5 类）
//
// C 里程碑起做 .direct；D 补 .live；F 补 .party（安卓 callerType==5）。
// .match / .bot 枚举位预留。
enum CallFrontGameType: Int {
    case direct = 1   // 直接拨打
    case match  = 2   // 视频匹配
    case live   = 3   // 直播间私 call（D）
    case bot    = 4   // 机器人通话（J）
    case party  = 5   // 派对房私 call（F · 对齐安卓 callerType==5）
}

// MARK: - callRate 接通率四节点（POST /callRate body）

enum CallRateCategory: Int {
    case answered  = 1   // 接听
    case rejected  = 2   // 拒接
    case timeout   = 3   // 超时未接
    case canceled  = 4   // 取消
}

enum CallRateType: Int {
    case callee = 1      // 被叫
    case caller = 2      // 主叫
}

enum CallRateUserType: Int {
    case user   = 1      // 普通用户
    case anchor = 2      // 主播（本端固定 2）
}

// MARK: - 调优常量

enum CallTuning {
    /// 主叫拨出超时 30s（与 H5 callTimeOutNum 一致）
    static let callOutTimeoutSeconds: TimeInterval = 30
    /// 被叫待接听超时 30s（与 H5 g-waitingCall 的 overtime 一致）
    static let callInTimeoutSeconds: TimeInterval = 30
    /// joinCall 拉对方资料 3s 超时（H5 useCallApi.joinCallGetUserInfo Promise.race）
    static let joinCallTimeoutSeconds: TimeInterval = 3
    /// RTM 快速重试梯度（秒），累计 7s 覆盖瞬时抖动
    static let rtmQuickRetryDelays: [TimeInterval] = [1, 2, 4]
    /// RTM 快重试用尽后的慢重试节奏
    static let rtmSlowRetryInterval: TimeInterval = 5
    /// RTM token TTL（24h，与后端签发一致）
    static let rtmTokenTTL: TimeInterval = 24 * 60 * 60
    /// 提前续 token 的窗口
    static let rtmTokenRenewAhead: TimeInterval = 30
    /// SAME_UID_LOGIN 触发 logout 的延迟（给埋点 flush 留窗口，与 H5 一致）
    static let sameUidLogoutDelayMs: Int = 500
    /// C-3 通话异常自检 tenSecondsCB 周期（H5 topBar.vue 每 10s 检查）
    static let abnormalCheckPeriodSeconds: Int = 10
    /// C-3 secondsToZero 阈值（H5 通话 >120s 且收入=0 判定收入异常）
    static let incomeZeroThresholdSeconds: Int = 120
}

// MARK: - C-3 通话异常自检（H5 g-faceTime/topBar.vue tenSecondsCB + secondsToZero）
//
// H5 语义映射（详见 C-spec-通话异常自检topBar-202607071742.md §0.4）：
// - userOffline     → H5 checkRemoteIsJoined 失败       → iOS agora.remoteUid == 0
// - networkUnstable → H5 connectionStateIsConnected 失败 → iOS agora.state != .joined
// - incomeZero      → H5 secondsToZero                  → iOS elapsed>120 && callIncome==0
enum CallAbnormalReason: String, Identifiable, CaseIterable {
    case userOffline
    case networkUnstable
    case incomeZero

    var id: String { rawValue }
}
