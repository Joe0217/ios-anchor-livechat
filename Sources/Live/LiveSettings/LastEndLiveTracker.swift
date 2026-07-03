import Foundation

/// 60s 冷却基建（B-spec-开播设置页 §1.3）。
///
/// 存储 key **复用** `LiveStore.endLive()` / `LiveStore.forceEnd()` 已在写的 UserDefaults
/// key `"lastEndAt"`，避免 v1/v2 分裂。本类型只做**读**封装（可在测试里换 UserDefaults suite）。
///
/// H5 对齐：`liveStore.lastEndLiveTime` 仅在 `handleEndLive` 尾部记，不在开播失败/回滚里记 —— iOS 严格遵循同语义。
enum LastEndLiveTracker {
    /// UserDefaults key，与 LiveStore.endLive/forceEnd 写入端一致
    static let key = "lastEndAt"

    /// 上次成功下播（含 forceEnd）到现在过去了多少秒；从未下播过返 nil。
    static var secondsSinceLast: TimeInterval? {
        guard let date = UserDefaults.standard.object(forKey: key) as? Date else { return nil }
        return Date().timeIntervalSince(date)
    }
}
