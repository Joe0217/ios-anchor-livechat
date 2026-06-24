import Foundation

/// G 里程碑 spec §2.5：PK 会话上下文（进 inPK / punishing 期间 PKStore 持有）。
///
/// 字段来源：
/// - `pkId`：joinPk 响应 / handleInviteAccepted 子分支 / handleMatchSuccess
/// - `oppositeUserId` / `oppositeChannel` / `oppositeYxAccId`：匹配成功或邀请接受时拿到
/// - `endTime`：**本地自算 `Date() + duration`**（H5 livePk.js:685 同行为；后端不下发，PKJoinResponse.endTime 仅兼容）
/// - `pkType`：1 随机 / 2 邀请；用于埋点/UI 文案
///
/// 中断重连（M5）：reconcileOnReconnect 拿 getPkStatus 字符串与 ctx 校验远端是否仍 PK，
/// 进程被杀导致 ctx 内存丢失时直接当 PK 已退（H5 同行为，刷新页面 store 重置）。
struct PKContext: Equatable {
    let pkId: String
    let oppositeUserId: Int
    let oppositeNickname: String?
    let oppositeChannel: String?
    let oppositeYxAccId: String?
    let duration: Int        // 秒
    let endTime: Date        // 本地 Date() + duration 自算
    let pkType: PKType

    /// 当前剩余秒（负数夹到 0）。
    var remainingSeconds: Int {
        max(0, Int(endTime.timeIntervalSinceNow))
    }
}
