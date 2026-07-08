import Foundation

/// `/api/anchor/userInfo` 编辑页专用响应（I-spec §4.2.2 v3 · Step 3 反悔 #1）。
///
/// **真机抓包证实**（2026-07-07）：响应是 **flat** 结构 —— AnchorInfo 字段（nickname/icon/signature/...）
/// 与 `latestIconAndCallVideo`/`picList` **同层级**，**没有** `anchorInfo` wrapper key。
/// v1/v2 spec 假设有 `anchorInfo` 嵌套是错的（对齐 `ProfileService.getAnchorInfo()` 早就用
/// `decode(AnchorInfo.self, from:)` 直接顶层 decode 的实践）。
///
/// **实现**：`init(from decoder:)` 自定义 decode —— anchorInfo 从**顶层**取（`AnchorInfo.init(from:)`），
/// latestIconAndCallVideo/picList 从 keyed container 取（同层，可选字段）。
struct UserInfoWithReviewResponse: Decodable {
    let anchorInfo: AnchorInfo
    let latestIconAndCallVideo: [LatestIconAndCallVideo]?
    /// picList 与 AnchorInfo.pictures/videos 关系待 Step 3 后续抓包证实；
    /// 若 H5 用 picList 覆盖 pictures，iOS 抓包后决定用哪个
    let picList: [PicListItem]?

    private enum CodingKeys: String, CodingKey {
        case latestIconAndCallVideo
        case picList
    }

    init(from decoder: Decoder) throws {
        // anchorInfo 从顶层 decode（响应是 flat 结构，无 wrapper key）
        self.anchorInfo = try AnchorInfo(from: decoder)
        // latestIconAndCallVideo / picList 与 anchorInfo 字段同层，keyed container 取（可选）
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.latestIconAndCallVideo = try container.decodeIfPresent([LatestIconAndCallVideo].self, forKey: .latestIconAndCallVideo)
        self.picList = try container.decodeIfPresent([PicListItem].self, forKey: .picList)
    }

    /// Fake / Preview 用 memberwise init（自定义 init(from:) 移除了 auto-synthesis）
    init(anchorInfo: AnchorInfo,
         latestIconAndCallVideo: [LatestIconAndCallVideo]?,
         picList: [PicListItem]?) {
        self.anchorInfo = anchorInfo
        self.latestIconAndCallVideo = latestIconAndCallVideo
        self.picList = picList
    }

    /// H5 `mineInfo.picList` 元素结构
    struct PicListItem: Decodable, Equatable {
        let id: Int?
        let mediaUrl: String?
        let mediaType: Int?    // 1=图片 2=视频
        let vaild: Int?        // 1/2/3
        let coverUrl: String?
    }
}
