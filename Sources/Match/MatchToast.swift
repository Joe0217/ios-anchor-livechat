import Foundation

/// L 里程碑：MatchStore 状态迁移触发的 toast 语义类型。
///
/// **纯数据 enum**，不依赖 L10n —— MatchStore（属 test target sources）可直接引用；
/// UI 层通过 `MatchToast+Localized` extension 走 L10n 映射到具体展示文案。
///
/// 这是为了绕过 test target 独立 module 的限制：test target 不导入 L10n / DebugLocaleStore
/// SwiftUI 环境栈，因此 Store 层不能直接 `L10n.matchToastXxx`；enum 语义化 + View 层
/// mapping 是标准解耦模式（对齐工程内 `BlocklistViewModel+Runtime` 拆分思路）。
enum MatchToast: Equatable {
    /// R3/R4：网络失败（isMatchOpen / toggleMatch 抛异常）
    case networkError
    /// R1：人脸识别失败被封禁（isOpen 返 2）
    case noFaceDetected
    /// R2：超过匹配次数上限（isOpen 返 3）
    case exceedCount
    /// R4：toggleMatch(1) 返 false（后端拒绝）
    case turnOnFailed
    /// F3：openMatch 成功
    case turnOnSucceed
    /// F4/R10：closeMatch / handleIMOffline 完成
    case turnOffSucceed
    /// R6：cameraSession 3s 开启超时
    case cameraStartFailed
    /// R9：cameraSession interruption >= 30s 未恢复
    case cameraUnavailable
}
