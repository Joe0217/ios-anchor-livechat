import Foundation

/// 开播设置页状态机（B-spec-开播设置页 §2.1）。
///
/// 迁移规则：
/// - `.loading → .editing`（首次拉取 getMyLiveRoom 完成）
/// - `.loading → .error`（拉取失败 or userType 守卫失败）
/// - `.editing → .starting`（4 项 checkCanLive 全过）
/// - `.editing → .error`（4 项 checkCanLive 任一失败）
/// - `.starting → .error`（LiveService.startLive throws，非 1004/1005）
/// - `.starting` 成功不迁移，View 通过 `roomInfo` 触发 navigation push
/// - **`.error → .editing`**（用户改简介 or 调美颜滑块 or startTapped 首行自清；红队 🟠#6）
///
/// 非法迁移：`.loading → .starting`（必须过 editing）；`.starting → .editing 外`
enum LiveSettingsState: Equatable {
    case loading
    case editing
    case starting
    case error(String)
}
