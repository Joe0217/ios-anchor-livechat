import Foundation

/// 私聊会话类型（H-3 spec §1.5.13 / §4.2.2；Batch 3.8 拆 3 态区分 system / customer）。
///
/// **判定规则**：ChatDetailContainer 按 peerYxAccId 派生：
/// - `AppConfig.notificationYxAccId` (video-sky-*) → `.system`
/// - `CustomerServiceIdStore.customerYxAccId`     → `.customer`
/// - 其余                                          → `.regular`
///
/// **按钮行显隐**：
/// - `.regular`：4 按钮（麦克风 / 视频通话 / 普通相册 / 私密相册）—— 视频按 CallAuthBridge.canCall 隐藏
/// - `.customer`：**仅系统相册按钮**（隐麦克风 / 视频 / 私密；相册按钮走 iOS `PhotosPicker` 读手机相册，非主播上传相册）
/// - `.system`：**无输入栏 + 无底部操作栏**（只读，用户不可回复系统通知）
enum ChatType: Equatable {
    case regular
    case customer
    case system
}
