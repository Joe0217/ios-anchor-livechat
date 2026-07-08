import Foundation

/// `/api/anchor/userInfo` 响应里 `latestIconAndCallVideo[]` 元素结构（I-spec §4.2.2）。
///
/// - `businessType == 2`：头像；vaild==2 表示头像审核中
/// - `businessType == 3`：来电视频；vaild==2 表示审核中
struct LatestIconAndCallVideo: Decodable, Equatable {
    let id: Int?
    let businessType: Int?    // 2=头像 3=来电视频
    let mediaUrl: String?
    let vaild: Int?           // 1=有效 2=审核中 3=被拒（H5 拼写沿用）
}

/// 提取头像审核态（对齐 spec §2.3）
extension Array where Element == LatestIconAndCallVideo {
    /// 是否头像审核中（businessType==2 && vaild==2）
    var isAvatarReviewing: Bool {
        contains { $0.businessType == 2 && $0.vaild == 2 }
    }

    /// 是否头像被拒（businessType==2 && vaild==3）—— 用户产品需求 2026-07-07：
    /// H5 index.vue:79-86 头像有三态视觉（审核中 / 被拒 / 正常）；iOS 补齐拒绝态
    var isAvatarRejected: Bool {
        contains { $0.businessType == 2 && $0.vaild == 3 }
    }

    /// 提取当前有效来电视频（businessType==3 && vaild==1）
    var currentCallVideo: LatestIconAndCallVideo? {
        first { $0.businessType == 3 && $0.vaild == 1 }
    }

    /// 审核中头像的 mediaUrl（对齐 H5 profile/index.vue:80-85）
    ///
    /// H5 行为：审核中时 UI 显示的是"提交审核的新头像图片"（`findItem.mediaUrl`），
    /// 而非"当前已通过审核的老头像"（`anchor.icon`）。用户在编辑页看到的是"我提交的哪张图正在被审核"。
    ///
    /// iOS 之前只用 `isAvatarReviewing` bool 标记审核态，丢弃了 mediaUrl —— 展示还是 anchor.icon 老图。
    /// 本 helper 让 buildLoadArtifacts 能拿到审核中头像 URL 填入 draft.avatarUrl。
    var reviewingAvatarMediaUrl: String? {
        first { $0.businessType == 2 && $0.vaild == 2 }?.mediaUrl
    }
}
