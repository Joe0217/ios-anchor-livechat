import Foundation

/// L 里程碑：Match 相关的 UserDefaults 持久化字段封装。
///
/// 对齐 H5 `stores/modules/user.js:48` `persist.paths` 中含 `isMatchBlocked / todayShowMatchPopup`，
/// 以及 `useMatch.js` localStorage `match_today_date / match-pop-show-time`。
///
/// **key 命名**：全部 `match.` prefix 避免全局命名冲突（v3 RA23）。
/// **时区**：日期字段按**设备本地时区** YYYY-M-D 格式（对齐 H5 `useMatch.js:52-68`，v3 §0.3 #5）。
struct MatchPersistedState: Codable, Equatable {
    /// 匹配功能被封禁（超次数 / 人脸识别失败 / 后端 isOpen 返 2/3）。
    /// 出口边：用户主动点开启 + isOpen 返 1 时清 false。
    var isMatchBlocked: Bool = false

    /// 是否勾选"今日不再提醒"10 分钟匹配提示弹窗。
    /// **注意语义反向**：false=未勾选可弹（默认）；true=已勾选不弹。
    /// 对齐 H5 `todayShowMatchPopup` 但改名避免歧义（v3 §3.2 RA12）。
    var todayNoReminderChecked: Bool = false

    /// 首日规则弹窗已同意日 YYYY-M-D。用于判定"今日首次开启"是否弹规则弹窗。
    /// H5 `useMatch.js` STORAGE_KEY='match_today_date'。
    var ruleAgreedDate: String = ""

    /// 10 分钟提示弹窗跨自然日重置基准日 YYYY-M-D。
    /// H5 `c-goMatch.vue:457` saveTodayDate('match-pop-show-time')。
    /// 跨自然日 `isFirstOpenToday('tipShownDate')` 触发重启 setInterval 定时器。
    var tipShownDate: String = ""
}

/// UserDefaults 读写封装。使用 4 独立 key（非整 struct 序列化）便于跨版本兼容 + 单字段更新原子。
/// 生产调用必须传 userID；nil 命名空间仅保留给逻辑测试，避免切账号时共享封禁和弹窗日期。
enum MatchPersistedStore {
    private static let defaults = UserDefaults.standard

    // UserDefaults key（v3 RA23：全部 match. prefix）
    private enum Keys {
        static let isMatchBlocked = "match.isMatchBlocked"
        static let todayNoReminderChecked = "match.todayNoReminderChecked"
        static let ruleAgreedDate = "match.ruleAgreedDate"
        static let tipShownDate = "match.tipShownDate"
    }

    // MARK: - 整体加载（冷启动用）

    static func load(userID: Int? = nil) -> MatchPersistedState {
        MatchPersistedState(
            isMatchBlocked: defaults.bool(forKey: key(Keys.isMatchBlocked, userID: userID)),
            todayNoReminderChecked: defaults.bool(forKey: key(Keys.todayNoReminderChecked, userID: userID)),
            ruleAgreedDate: defaults.string(forKey: key(Keys.ruleAgreedDate, userID: userID)) ?? "",
            tipShownDate: defaults.string(forKey: key(Keys.tipShownDate, userID: userID)) ?? ""
        )
    }

    // MARK: - 单字段写入

    static func saveIsMatchBlocked(_ value: Bool, userID: Int? = nil) {
        defaults.set(value, forKey: key(Keys.isMatchBlocked, userID: userID))
    }

    static func saveTodayNoReminderChecked(_ value: Bool, userID: Int? = nil) {
        defaults.set(value, forKey: key(Keys.todayNoReminderChecked, userID: userID))
    }

    static func saveRuleAgreedDate(_ value: String, userID: Int? = nil) {
        defaults.set(value, forKey: key(Keys.ruleAgreedDate, userID: userID))
    }

    static func saveTipShownDate(_ value: String, userID: Int? = nil) {
        defaults.set(value, forKey: key(Keys.tipShownDate, userID: userID))
    }

    // MARK: - 单测清空

    /// **仅供单测使用**：清空所有 Match 相关 UserDefaults 键。
    static func resetForTesting(userID: Int? = nil) {
        defaults.removeObject(forKey: key(Keys.isMatchBlocked, userID: userID))
        defaults.removeObject(forKey: key(Keys.todayNoReminderChecked, userID: userID))
        defaults.removeObject(forKey: key(Keys.ruleAgreedDate, userID: userID))
        defaults.removeObject(forKey: key(Keys.tipShownDate, userID: userID))
    }

    private static func key(_ base: String, userID: Int?) -> String {
        guard let userID else { return base }
        return "\(base).user.\(userID)"
    }
}

// MARK: - 日期工具

/// 日期格式化 YYYY-M-D（对齐 H5 `useMatch.js:53-56`：`${y}-${m+1}-${d}`，**M 月不补零**）。
/// 使用**设备本地时区**（对齐 H5，见 v3 §0.3 #5）。
enum MatchDateHelper {
    /// 生成"今天"的字符串（YYYY-M-D，设备本地时区）。
    static func todayString(now: Date = Date(), calendar: Calendar = .current) -> String {
        let comp = calendar.dateComponents([.year, .month, .day], from: now)
        return "\(comp.year ?? 0)-\(comp.month ?? 0)-\(comp.day ?? 0)"
    }

    /// 判断给定日期字符串是否**不等于今天**（等价 H5 `isFirstOpenToday` 语义：
    /// 保存的日期 ≠ 今天 → 返回 true，即"今日首次"）。
    /// - `savedDate` 空字符串 or 与今天不同 → 返 true
    static func isFirstToday(savedDate: String, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        return savedDate != todayString(now: now, calendar: calendar)
    }
}
