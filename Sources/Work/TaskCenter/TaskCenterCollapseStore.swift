import Foundation

/// 任务中心页模块折叠态持久化。
///
/// 对齐 H5 [`views/task/index.vue:23,72-103`](../../../../Desktop/HN/anchor-livechat-h5/src/views/task/index.vue)
/// 的 `taskCenter:collapsedModules:${cycle}` localStorage key(存 JSON 数组 moduleCode)。
///
/// iOS 侧 UserDefaults key 挂 **userId 前缀**,切账号 clear 避免账号 A 折叠态污染账号 B
/// (对齐 [session-scoped-store-refresh](.claude/rules/session-scoped-store-refresh.md))。
enum TaskCenterCollapseStore {
    enum WeeklySection: String, CaseIterable {
        case tycoon
        case points
    }
    /// UserDefaults key 构造:`taskCenter.collapse.<cycle>.<userId>`
    private static func key(cycle: TaskCycle, userId: String) -> String {
        "taskCenter.collapse.\(cycle.rawValue).\(userId)"
    }

    private static func weeklySectionKey(_ section: WeeklySection, userId: String) -> String {
        "taskCenter.weeklySection.\(section.rawValue).\(userId)"
    }

    /// 从 UserDefaults 恢复折叠模块 moduleCode 集合。
    static func load(cycle: TaskCycle, userId: String) -> Set<String> {
        guard !userId.isEmpty,
              let raw = UserDefaults.standard.data(forKey: key(cycle: cycle, userId: userId)),
              let arr = try? JSONDecoder().decode([String].self, from: raw)
        else { return [] }
        return Set(arr)
    }

    /// 持久化折叠模块 moduleCode 集合。
    static func save(cycle: TaskCycle, userId: String, collapsed: Set<String>) {
        guard !userId.isEmpty else { return }
        let arr = Array(collapsed)
        if let data = try? JSONEncoder().encode(arr) {
            UserDefaults.standard.set(data, forKey: key(cycle: cycle, userId: userId))
        }
    }

    /// H5 的 Active Tycoon / Integral 两个 Weekly 独有区块默认收起，且分别持久化。
    static func loadWeeklySectionExpanded(_ section: WeeklySection, userId: String) -> Bool {
        guard !userId.isEmpty,
              UserDefaults.standard.object(forKey: weeklySectionKey(section, userId: userId)) != nil
        else { return false }
        return UserDefaults.standard.bool(forKey: weeklySectionKey(section, userId: userId))
    }

    static func saveWeeklySectionExpanded(_ section: WeeklySection, userId: String, isExpanded: Bool) {
        guard !userId.isEmpty else { return }
        UserDefaults.standard.set(isExpanded, forKey: weeklySectionKey(section, userId: userId))
    }

    /// 切账号 logout 时清指定用户的两个 cycle 折叠态(避免下次同帐号进入残留)。
    static func clear(userId: String) {
        guard !userId.isEmpty else { return }
        for cycle in TaskCycle.allCases {
            UserDefaults.standard.removeObject(forKey: key(cycle: cycle, userId: userId))
        }
        for section in WeeklySection.allCases {
            UserDefaults.standard.removeObject(forKey: weeklySectionKey(section, userId: userId))
        }
    }
}
