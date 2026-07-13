import Foundation

/// 开播设置页状态机（B-spec-开播设置页 §2.1）。
///
/// 迁移规则：
/// - `.loading → .editing`（首次拉取 getMyLiveRoom 完成）
/// - `.editing → .starting`（4 项 checkCanLive 全过）
/// - `.editing → .error`（cover 上传失败）
/// - `.starting → .editing`（cover 上传失败 或 1004/1005 短路）
/// - `.starting` 成功不迁移，View 通过 `roomInfo` 触发 navigation push
/// - **`.error → .editing`**（用户改简介 or 调美颜滑块 or startTapped 首行自清；红队 🟠#6）
///
/// **无直播权限 / getMyLiveRoomV2 / beginLiveRoom 接口报错**（含 code=1111 request.failed 等）
/// **不再迁移到 `.error`**，而是走 store 的 `showErrorAndDismiss` → toast 提示 + 1.5s 自动 pop
/// 返回上级页面。`.error` 态目前仅由 cover 上传失败触发（用户可重试封面）。
///
/// 非法迁移：`.loading → .starting`（必须过 editing）；`.starting → .editing 外`
enum LiveSettingsState: Equatable {
    case loading
    case editing
    case starting
    case error(String)
}
