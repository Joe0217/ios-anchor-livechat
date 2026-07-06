import Foundation

/// 首次开播规则页守卫（对齐 H5 `stores/user.js` `isFirstLive` 持久化）。
///
/// - 触发：Work → tap Go Live 按钮时判断
///   - `isFirstLive == true`（未开过播）→ push FirstLiveRuleView（10s 倒计时规则页）
///   - `isFirstLive == false`（已开过播）→ 直接 push LiveSettingsView
/// - 生效：一辈子只弹一次。FirstLiveRuleView 倒计时到 0 时置 false（对齐 H5
///   firstLiveRule.vue:24 —— 不是点 Confirm 才置 false，而是倒计时结束就置；即使用户 back 也不再弹）
///
/// 存储：UserDefaults `live.isFirstLive.v1`；默认 true（新账号从未开过播）。
/// 多账号共享设备场景暂不隔离（H5 也是全局 localStorage，与账号切换无关）
enum FirstLiveTracker {
    private static let key = "live.isFirstLive.v1"

    /// 首次读取默认 true（对齐 H5 user.js:46-48 `isFirstLive = true` 默认）
    static var isFirstLive: Bool {
        // 若从未 set 过（新账号）→ true；set 过 false → false
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// 首次规则页 10s 倒计时结束时调（对齐 H5 firstLiveRule.vue:24）
    static func markConsumed() {
        UserDefaults.standard.set(false, forKey: key)
    }

    #if DEBUG
    /// DEBUG 期重置——供 Work → Hi 按钮 sheet 触发，方便反复测试规则页
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
    #endif
}
