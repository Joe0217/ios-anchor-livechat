import Foundation

/// 主播在线状态数值定义（对齐 H5 `constant/live.ts` `LIVE_STATUS_NUMBER` + 安卓 `NIMOnlineStatus`）。
///
/// **来源**：字段 `onlineGroupStatus` 由 `POST /api/anchor/batchQueryYxStat` 返回。
///
/// **落地方案决策**（对比安卓 / H5）：
/// - **安卓**：NIM subscribeOnlineStateEvent 云信推送 + WS 15s 心跳（双通道）
/// - **H5**：`apiBatchQueryYxStatByUid` 定时轮询（10-30s）+ WS 5s 心跳（单通道观察 + 单通道上报）
/// - **iOS 选 H5 方案（观察他人部分）**：复用 `ConversationProfileService` 的 `apiBatchQueryYxStat`
///   已含 `onlineGroupStatus`；不额外接云信 event subscribe。**"上报自己"独立里程碑，不在 Message tab 范围**
enum AnchorOnlineStatus {
    /// 云信已登录（主播主状态 1）
    static let online: Int = 1
    /// 云信已登出（主播主状态 3）
    static let offline: Int = 2
    /// 连接已断开（主播主状态 3）
    static let disconnect: Int = 3
    /// 通话中（主播主状态 2）
    static let calling: Int = 10000
    /// 通话结束（主播主状态 1）
    static let callEnd: Int = 10001
    /// 回到前台（主播主状态 1）
    static let foreground: Int = 10002
    /// 退到后台（主播主状态 2）
    static let background: Int = 10003
    /// 开启勿扰（主播主状态 2）
    static let doNotDisturbOpen: Int = 10004
    /// 关闭勿扰（主播主状态 1）
    static let doNotDisturbClose: Int = 10005
    /// 匹配模式（主播主状态 1）
    static let onMatchMode: Int = 10006

    /// 是否"可通话/在线"（对齐安卓 `isActiveStatus` + H5 判定：主状态 1 的 5 个 case + 匹配模式）。
    /// 通话中 CALLING、忙 BACKGROUND / DND_OPEN 不算"绿点"。
    static func isOnlineForCall(_ status: Int?) -> Bool {
        guard let s = status else { return false }
        return s == online
            || s == callEnd
            || s == foreground
            || s == doNotDisturbClose
            || s == onMatchMode
    }
}
