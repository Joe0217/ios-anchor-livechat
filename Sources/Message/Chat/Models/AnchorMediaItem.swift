import Foundation

/// 主播相册项统一层（H-2 spec §2.1）—— view 层消费的类型。
///
/// **数据源**：从 [Sources/Profile/ProfileModels.swift](../../../Profile/ProfileModels.swift) 里
/// `AnchorInfo.pictures[]` + `AnchorInfo.videos[]` 组装（two arrays → 一个扁平列表）。
///
/// **用户端 vs 主播端**：主播端只能选自己 profile 里的已有 pictures/videos 发送，**不能上传**新文件
/// （对齐 H5 `AlbumPopup` type=1 语义）。
struct AnchorMediaItem: Identifiable, Equatable, Hashable {
    let id: String                    // MediaAsset.id 直接沿用
    let mediaUrl: URL
    let coverUrl: URL?                // video 的 poster；image 传 nil
    let kind: MediaKind
    let dur: Int?                     // video 秒数（image 传 nil）
}

enum MediaKind: String, Equatable, Hashable {
    case image
    case video
}

// MARK: - 从 AnchorInfo.pictures[] / .videos[] 组装

extension AnchorMediaItem {
    /// 从 `MediaAsset` 组装（图片路径）。
    /// **过滤规则**：`url` 空 / `valid != 1`（审核未过）→ 返 nil，UI 不展示。
    static func fromPicture(_ asset: MediaAsset) -> AnchorMediaItem? {
        guard let urlString = asset.url, let url = URL(string: urlString),
              (asset.vaild ?? 1) == 1 else { return nil }
        return AnchorMediaItem(
            id: asset.id,
            mediaUrl: url,
            coverUrl: nil,
            kind: .image,
            dur: nil
        )
    }

    /// 从 `MediaAsset` 组装（视频路径）。视频需要 coverUrl 作为 poster；缺失时 return nil（无预览图不展示）。
    static func fromVideo(_ asset: MediaAsset) -> AnchorMediaItem? {
        guard let urlString = asset.url, let url = URL(string: urlString),
              (asset.vaild ?? 1) == 1 else { return nil }
        let cover = asset.coverUrl.flatMap { URL(string: $0) }
        return AnchorMediaItem(
            id: asset.id,
            mediaUrl: url,
            coverUrl: cover,
            kind: .video,
            dur: nil   // MediaAsset 目前不含 dur 字段；step 3 真机 verify 是否需要补
        )
    }

    /// 从 `UserInfoWithReviewResponse.PicListItem` 单条组装（Batch 3.6 加：真接口相册用 picList 单数组分流）。
    ///
    /// **过滤规则**：`mediaUrl` 空 / `vaild != 1`（审核未过）→ 返 nil。
    static func fromPicListItem(_ item: UserInfoWithReviewResponse.PicListItem) -> AnchorMediaItem? {
        guard let urlString = item.mediaUrl, let url = URL(string: urlString),
              (item.vaild ?? 1) == 1 else { return nil }
        let kind: MediaKind = (item.mediaType == 2) ? .video : .image
        let cover = item.coverUrl.flatMap { URL(string: $0) }
        return AnchorMediaItem(
            id: "\(item.id ?? -1)",
            mediaUrl: url,
            coverUrl: cover,
            kind: kind,
            dur: nil
        )
    }

    /// `PicListItem[]` 分流为 AnchorMediaItem 列表（图 + 视频合并）。
    static func fromPicList(_ items: [UserInfoWithReviewResponse.PicListItem]?) -> [AnchorMediaItem] {
        (items ?? []).compactMap(AnchorMediaItem.fromPicListItem)
    }

    /// Batch 3.7：从 `PrivateMedia` 转 AnchorMediaItem（私密相册数据源）。
    ///
    /// **视频封面**：H5 私密结构无独立 coverUrl；视频缩略图 H5 用 `<video preload=metadata>` 首帧，
    /// iOS 端 `MediaPickerSheet.thumbnail` 已有 `coverUrl ?? mediaUrl` fallback，视频列表暂用 videoUrl 作 poster（AVAsset 首帧）
    static func fromPrivateMedia(_ p: PrivateMedia) -> AnchorMediaItem? {
        guard let url = URL(string: p.originalUrl) else { return nil }
        return AnchorMediaItem(
            id: p.id,
            mediaUrl: url,
            coverUrl: nil,
            kind: p.isVideo ? .video : .image,
            dur: nil
        )
    }


    /// 统一入口：`pictures[]` + `videos[]` 组装为一个扁平列表，按 createTime 降序（最新在前）。
    static func compose(pictures: [MediaAsset]?, videos: [MediaAsset]?) -> [AnchorMediaItem] {
        let pics = (pictures ?? []).compactMap(AnchorMediaItem.fromPicture)
        let vids = (videos ?? []).compactMap(AnchorMediaItem.fromVideo)
        let all = pics + vids
        // createTime 降序（新在前）；无 createTime 排后
        return all.sorted { lhs, rhs in
            let lct = pictures?.first(where: { $0.id == lhs.id })?.createTime
                ?? videos?.first(where: { $0.id == lhs.id })?.createTime ?? 0
            let rct = pictures?.first(where: { $0.id == rhs.id })?.createTime
                ?? videos?.first(where: { $0.id == rhs.id })?.createTime ?? 0
            return lct > rct
        }
    }
}
