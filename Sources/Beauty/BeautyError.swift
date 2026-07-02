import Foundation

/// 美颜引擎错误分类（K spec §6.1 #11 BeautyEngineErrorClassifier，红队 D4）。
///
/// 区分 authpack 过期 vs bundle 损坏 vs 通用 setup 失败——UI 文案不同：
/// - `.authExpired` → "请更新 App 后重试"
/// - `.bundleMissing` → "美颜资源损坏，请重新安装"
/// - `.genericSetupFailed` → "美颜引擎初始化失败"
/// - `.setupTimeout` → 500ms 阈值超时（保留 B 里程碑 spec §6.1 语义）
/// - `.persistenceDecodeFailed` → UserDefaults JSON corrupt，Store 兜底默认档
/// - `.persistenceWriteFailed` → 写盘失败（disk full 等），只 log 不炸
enum BeautyError: Error, Equatable {
    case authExpired
    case bundleMissing
    case genericSetupFailed
    case setupTimeout(elapsed: TimeInterval)
    case persistenceDecodeFailed(reason: String)
    case persistenceWriteFailed(reason: String)

    /// 是否属于渲染层严重错误（触发降级 PassthroughRenderer）
    var isRendererFatal: Bool {
        switch self {
        case .authExpired, .bundleMissing, .genericSetupFailed, .setupTimeout:
            return true
        case .persistenceDecodeFailed, .persistenceWriteFailed:
            return false
        }
    }

    /// L10n key 前缀（Step 1b UI 层用此拼装 alert 文案）
    var localizationKey: String {
        switch self {
        case .authExpired: return "beauty.error.authExpired"
        case .bundleMissing: return "beauty.error.bundleMissing"
        case .genericSetupFailed: return "beauty.error.genericSetupFailed"
        case .setupTimeout: return "beauty.error.setupTimeout"
        case .persistenceDecodeFailed: return "beauty.error.persistenceDecodeFailed"
        case .persistenceWriteFailed: return "beauty.error.persistenceWriteFailed"
        }
    }
}
