import Foundation

// MARK: - 页面级 Phase（对齐 I-spec §3.1）
//
// 状态转移图：
//   loading → editing → saving → success → dismiss
//                    ↘ (无变更) → dismiss
//        ↘ loadError → Retry → loading
//   Any → terminated（apiSessionInvalidated 触发，强制 dismiss）
//
// `terminated` 由 SessionStore 的 .apiSessionInvalidated 通知触发，任何 phase 都强制转
// 该态 → view 层 dismiss；不弹 success alert 即使刚 saving 成功。

enum EditProfilePhase: Equatable {
    case loading
    case editing
    case saving
    case success
    case loadError(String)
    case terminated
}

// MARK: - 字段级上传子态（每 DraftMediaItem 独立）
//
// idle → uploading → idle（成功）
//              ↘ failed → uploading（retry）
//                    ↘ (remove from draft)
//
// 覆盖上传（uploading → uploading）：前一个 task cancel + Upload Epoch 递增，
// 老 task 完成时 guard 丢弃结果。

enum FieldUploadState: Equatable, Sendable {
    case idle
    case uploading(localId: String)
    case failed(message: String)
}

// MARK: - Draft 编辑草稿（用户当前输入但未提交）

struct DraftMediaItem: Identifiable, Equatable, Sendable {
    /// 稳定 id："asset-\(serverId)"（原图）or "local-\(uuid)"（新增）
    let id: String
    /// 非 nil = 原图；diff 时进 picsDel 候选（依 uploadState 判定）
    let serverId: Int?
    var url: String
    var coverUrl: String?
    var uploadState: FieldUploadState
    /// 服务端审核态：1=有效 / 2=审核中 / 3=拒绝。新增图 nil；原图透传 MediaAsset.vaild。
    /// 用户明示需求 2026-07-07：审核中的 tile 要显示"In Review"标签（对齐 ProfileMediaGrid pattern）
    var vaild: Int?

    static func asset(_ media: MediaAsset) -> DraftMediaItem {
        DraftMediaItem(
            id: "asset-\(media.assetId ?? -1)",
            serverId: media.assetId,
            url: media.url ?? "",
            coverUrl: media.coverUrl,
            uploadState: .idle,
            vaild: media.vaild
        )
    }

    static func newLocal(url: String = "",
                         coverUrl: String? = nil,
                         localId: String = UUID().uuidString) -> DraftMediaItem {
        DraftMediaItem(
            id: "local-\(localId)",
            serverId: nil,
            url: url,
            coverUrl: coverUrl,
            uploadState: .uploading(localId: localId),
            vaild: nil
        )
    }

    /// 服务端审核态派生
    var isServerReviewing: Bool { vaild == 2 }
    var isServerRejected: Bool { vaild == 3 }
}

struct DraftGreetMsg: Identifiable, Equatable, Sendable {
    /// 稳定 id："server-\(serverId)"（原有）or "local-\(uuid)"（新增）
    let id: String
    /// 非 nil = 原有；diff 时判定"是否服务端已知"
    let serverId: Int?
    var content: String

    static func server(_ msg: GreetMsg) -> DraftGreetMsg {
        DraftGreetMsg(
            id: "server-\(msg.serverId ?? -1)",
            serverId: msg.serverId,
            content: msg.contentDetail ?? ""
        )
    }

    static func newLocal(content: String) -> DraftGreetMsg {
        DraftGreetMsg(
            id: "local-\(UUID().uuidString)",
            serverId: nil,
            content: content
        )
    }
}

struct DraftState: Equatable, Sendable {
    var nickname: String
    var avatarUrl: String
    var signature: String
    var photos: [DraftMediaItem]
    var videos: [DraftMediaItem]
    var callVideo: DraftMediaItem?
    var greetMsgs: [DraftGreetMsg]

    static let empty = DraftState(
        nickname: "",
        avatarUrl: "",
        signature: "",
        photos: [],
        videos: [],
        callVideo: nil,
        greetMsgs: []
    )
}

// MARK: - Original Snapshot（diff 基线，loading 完成后写一次不再变）

struct OriginalSnapshot: Equatable {
    var nickname: String
    var avatarUrl: String
    var signature: String
    /// 只含 vaild != 3 的可见项（vaild=3 走 hiddenRejectedPhotoIds/VideoIds 强制 diff）
    var photos: [MediaAsset]
    var videos: [MediaAsset]
    var callVideo: MediaAsset?
    var greetMsgs: [GreetMsg]
    /// vaild=3 的照片 id（用户不可见，diff 强制加入 picsDel）
    var hiddenRejectedPhotoIds: [Int]
    var hiddenRejectedVideoIds: [Int]

    static let empty = OriginalSnapshot(
        nickname: "",
        avatarUrl: "",
        signature: "",
        photos: [],
        videos: [],
        callVideo: nil,
        greetMsgs: [],
        hiddenRejectedPhotoIds: [],
        hiddenRejectedVideoIds: []
    )
}

// MARK: - 审核态（哪些字段在审核中）

struct ReviewStatus: Equatable, Sendable {
    var nickname: Bool
    var signature: Bool
    /// 头像审核中（latestIconAndCallVideo 里 businessType=2 && vaild=2）
    var avatar: Bool
    /// 头像被拒（vaild=3）—— 用户产品需求 2026-07-07 P1：H5 有三态视觉，iOS 补齐
    var avatarRejected: Bool
    /// 审核中的问候语（只展示，不参与 draft 编辑）
    var reviewingGreetMsgs: [GreetMsg]

    static let none = ReviewStatus(
        nickname: false,
        signature: false,
        avatar: false,
        avatarRejected: false,
        reviewingGreetMsgs: []
    )
}

// MARK: - Toast 语义 key（对齐 spec §5 各 toast 场景；View 层翻译为 L10n 文案）

/// Toast 语义键（Store 层用；View 层通过 switch 翻译到 L10n）
/// 让 Store 保持零 L10n 依赖（test target 无需引入 L10n.swift）
enum EditProfileToastKey: Equatable, Sendable {
    case photosLimit                    // 相册满 9
    case videosLimit                    // 视频满 6
    case uploading                      // 有 uploading tile 时点 Confirm
    case uploadFailed                   // 有 failed tile 时点 Confirm
    case imageTooLarge                  // 图片 > 2MB
    case videoTooLarge                  // 视频 > 20MB
    case videoFormatUnsupported         // .avi 等不支持
    case avatarInReview                 // 头像审核中点击
    case nicknameInReview               // 昵称审核中点击
    case networkError                   // 网络错
    case uploadTimeout                  // 后台超时批量标 failed
    case apiError(code: String, message: String)  // 业务错误码 + 后端 message
}

// MARK: - 字段常量（对齐 H5 硬限）

enum EditProfileLimits {
    static let nicknameMaxLength = 15
    static let signatureMaxLength = 200
    static let greetMsgMaxLength = 50
    static let photosMaxCount = 9
    static let videosMaxCount = 6
    static let callVideoMaxCount = 1
    /// 图片单个上限：5 MB（用户产品决策 2026-07-07；H5 c-uploadImgsAndVideos.vue:31 是 2MB
    /// 但 iOS 侧决定放宽到 5MB 给用户更宽容的空间。真机验证过 ImageUploader `.moment` preset
    /// 压缩后一般 < 500KB，5MB 输入足够冗余，不会因为用户直接选高清照片被拒）
    static let imageMaxSizeBytes = 5 * 1024 * 1024
    /// 视频单个上限：20 MB（H5 c-uploadImgsAndVideos.vue:34；spec v2 §2.1 已更正）
    static let videoMaxSizeBytes = 20 * 1024 * 1024
    /// 允许的视频扩展名（iOS 收窄，PhotosPicker 只导出 mp4/mov）
    static let allowedVideoExtensions: Set<String> = ["mp4", "mov"]
}
