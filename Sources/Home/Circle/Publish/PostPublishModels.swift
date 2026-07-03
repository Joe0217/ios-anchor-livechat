import Foundation

// MARK: - 状态机

/// 发布朋友圈状态机（J spec §4.1）。
///
/// **不变量**：
/// - `uploadedUrls` 在 uploadingImages / creatingPost / failed 之间**保持单调累积**——
///   失败重试时 ViewModel 据此跳过已成功 idx，避免重传浪费（spec §4.1 + R8/R9/R16）
/// - 进入 `creatingPost(imgUrls:)` 时 `imgUrls.count == total`（所有图已上传成功）
/// - `success` 后状态机不可逆，view 销毁
enum PostingState: Equatable {
    case editing
    /// 上传 OSS 进行中。
    /// - progress：已成功上传张数
    /// - total：图片总数（imgs.count，本轮不变）
    /// - uploadedUrls：idx → cdnUrl 已成功的映射；失败重试时跳过已成功 idx
    case uploadingImages(progress: Int, total: Int, uploadedUrls: [Int: String])
    /// create 接口进行中。imgUrls 已全部就绪（已上传）。
    case creatingPost(imgUrls: [String])
    /// 发布成功（等 dismiss）。
    case success
    /// 失败可重试。uploadedUrls 保留供重试跳过已成功 idx。
    case failed(reason: FailureReason, uploadedUrls: [Int: String])
}

/// 失败原因（J spec §4.1 v3）。
///
/// v3 改动：删除 `createRejected` case，审核拒绝走通用 `createFailed(msg)`（对齐 H5 无专用码）。
enum FailureReason: Equatable {
    /// 文本空 + 有图（用户 Q3 决策：H5 强制 ≥1 文本）
    case textEmpty
    /// imgs 空（用户 Q3 决策：H5 强制 ≥1 图）
    case noImages
    /// STS getOssUploadParam 失败（含 2 次重拉耗尽，spec R6/R19）
    case credentialFailed
    /// 第 N 张图上传失败（同时整体失败，不发 create，spec R8）
    case uploadFailed(idx: Int)
    /// create 接口失败 + 业务消息（含审核拒绝，v3 不区分；imgUrls 可复用重试）
    case createFailed(msg: String)
    /// 网络兜底
    case network
}

// 注：`OssCredential` 已上移到 [Sources/Core/Upload/OssCredential.swift](../../../Core/Upload/OssCredential.swift)——
// 通用能力，多个业务共用（朋友圈发布 / 反馈截图 / 头像 / 相册）。

// MARK: - 常量

enum PostPublishLimits {
    /// 文本最大字符数（H5 maxlength="500"）
    static let maxTextLength = 500
    /// 最多图片数（H5 max-count="9"）
    static let maxImageCount = 9
    /// 单图原图阈值（KB，超过选图阶段直接拒；H5 max-size="10240"）。
    /// 与 [ImageCompressionPreset.moment.params.maxRawKB](../../../Core/Upload/ImageCompressionPreset.swift) 对齐。
    static let maxImageRawKB = 10_240
    /// STS 凭证刷新安全边际（秒）
    static let credentialRefreshMargin: TimeInterval = 300
    /// 单次发布最多 STS 重拉次数（防死循环；spec §3.1）
    static let maxCredentialRefreshPerPublish = 2
}

// MARK: - 跨模块通知

extension Notification.Name {
    /// 发布朋友圈成功后广播。
    /// MomentFeedStore (source=.me) 在 init 时 addObserver，收到后 set pendingReload=true；
    /// me sub-tab isActive 时真正 fetch（对齐 [.claude/rules/swiftui-keepalive-publisher-isolation.md](../../../../.claude/rules/swiftui-keepalive-publisher-isolation.md)）。
    static let momentPublished = Notification.Name("moment.published")
}
