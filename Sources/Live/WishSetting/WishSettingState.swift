import Foundation

/// WishSetting 页状态机（L-spec §2.1）。
///
/// 迁移：
/// - `.loading → .editing`：首次拉 getWishNum + templates（如需要）完成
/// - `.loading → .error`：网络/接口失败
/// - `.editing → .submittingTheme`：用户 tap Wish theme Submit（独立于 Save 主流程）
/// - `.submittingTheme → .editing`：submit 完成（成功或失败）
/// - `.editing → .error / .error → .editing`：任何用户输入自清
enum WishSettingState: Equatable {
    case loading
    case editing
    case submittingTheme
    case error(String)
}
