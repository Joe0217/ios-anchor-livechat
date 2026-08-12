import Foundation

/// 60s 冷却基建（B-spec-开播设置页 §1.3）。
///
/// 按 userID 存储，避免 A 刚下播后切到 B 时错误拦截 B；同账号重新登录仍保留冷却。
///
/// H5 对齐：`liveStore.lastEndLiveTime` 仅在 `handleEndLive` 尾部记，不在开播失败/回滚里记 —— iOS 严格遵循同语义。
enum LastEndLiveTracker {
    private static let keyPrefix = "lastEndAt.user"

    static func recordEnd(
        for userID: Int?,
        at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        guard let key = key(for: userID) else { return }
        defaults.set(date, forKey: key)
    }

    /// 上次成功下播（含 forceEnd）到现在过去了多少秒；从未下播过返 nil。
    static func secondsSinceLast(
        for userID: Int?,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> TimeInterval? {
        guard let key = key(for: userID),
              let date = defaults.object(forKey: key) as? Date else { return nil }
        return now.timeIntervalSince(date)
    }

    private static func key(for userID: Int?) -> String? {
        userID.map { "\(keyPrefix).\($0)" }
    }
}
