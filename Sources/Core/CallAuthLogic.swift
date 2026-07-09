import Foundation

/// H-3 视频通话权限的**纯语义函数**（对齐 H5 `user.js:52-56` `anchortCallAuth`）。
///
/// 与 `CallAuthBridge` 分离：Bridge 承担 Combine 接线（依赖 AnchorInfoStore.shared），
/// 本 enum 只承担 canCall 判定语义。**test target 可零依赖引用本文件覆盖 spec §F-32/F-33/F-35 + R-29/R-30**。
enum CallAuthLogic {
    /// **子串匹配**（对齐 H5 `_auth.includes(state.myAnchorInfo.userLevel)`）。
    ///
    /// - `isLoaded == false` → false（未 loaded 时按钮隐藏，不 flash 允许）
    /// - `achorHideButton == nil || .isEmpty` → false
    /// - `levelName == nil || .isEmpty` → false
    /// - 否则：`achorHideButton.contains(levelName)`
    ///
    /// **H5 quirk**：`String.contains("")` 返回 true —— iOS `String.contains` 语义同（`.range(of:)` 空串亦命中）。
    /// spec §R-30 明示"achorHideButton contains 空字符串 → true"是 H5 quirk 保留（levelName 空提前守卫 false）。
    static func canCall(achorHideButton: String?, levelName: String?, isLoaded: Bool) -> Bool {
        guard isLoaded,
              let auth = achorHideButton, !auth.isEmpty,
              let name = levelName, !name.isEmpty
        else { return false }
        return auth.contains(name)
    }
}
