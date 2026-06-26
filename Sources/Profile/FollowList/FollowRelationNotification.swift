import Foundation

extension Notification.Name {
    /// 关注关系变更：跨页同步 followFlag。userInfo: ["userId": Int, "followFlag": Int (0/1)]。
    /// 触发场景：FollowListViewModel.toggleFollow 成功后；ProfileViewModel / UserProfileViewModel 监听更新。
    /// 对应 H5/安卓的 LiveEventBus(REFRESH_FOLLOWING_LIST) 行为（蓝本 02-11 §4）。
    ///
    /// 抽出独立文件让 HilyTests target 可编译（FollowListModels.swift 含 FollowSegment 依赖 L10n，
    /// 不能入 HilyTests sources，本文件仅 Foundation 依赖可入）。
    static let followRelationChanged = Notification.Name("Hily.followRelationChanged")
}
