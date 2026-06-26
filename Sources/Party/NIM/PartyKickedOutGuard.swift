import Foundation

/// 1003 被踢双字段守护（spec §1.4.4 防误踢 / C 档单测用 / 零 SDK 依赖）。
///
/// 安卓确认 §3.4：payload schema `{seatIndex, roomId, userId}` 均为 **Number**；
/// HTTP `chat.roomId` 是 **String** → 跨通道走 `PartyValueNormalizer.stringify` 归一比较。
///
/// 守卫规则：`userId == 自己` && `roomId == 当前房` 双字段同时匹配才认。
/// 任一字段缺失、空、或不匹配均返回 false（路由侧丢弃该 1003，不进 forceLeaveRoom）。
enum PartyKickedOutGuard {

    /// 判定 1003 payload 是否针对自己 + 当前房。
    /// - parameter myUserId: 自己的用户 ID（调用方从 `SessionStore.shared.user?.userId` 注入；
    ///                       nil/空 一律 false 避免空登录态误触发）
    /// - parameter chatRoomId: 当前 chat 实例绑定的 roomId（HTTP String 形态）
    static func shouldHandle(payload: [String: Any],
                             myUserId: String?,
                             chatRoomId: String) -> Bool {
        guard let me = myUserId, !me.isEmpty else { return false }
        guard let target = PartyValueNormalizer.stringify(payload["userId"]),
              target == me else {
            return false
        }
        guard let r = PartyValueNormalizer.stringify(payload["roomId"]),
              r == chatRoomId else {
            return false
        }
        return true
    }
}
