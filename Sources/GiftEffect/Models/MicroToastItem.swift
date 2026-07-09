import Foundation

/// 礼物微 Toast 展示项（直播间底部轻量礼物通知条）
///
/// 对应 H5 礼物特效中的"小礼物 toast"样式：
/// 仅展示头像小图 + 礼物名 + 数量，不播动画，超时自动消失。
public struct MicroToastItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sceneKey: GiftEffectSceneKey
    /// 礼物小图 URL（用于 Toast 内缩略图展示，nil 时用占位图）
    public let imgUrl: String?
    public let giftName: String
    public let count: Int
    /// Toast 展示时长（秒），默认 3.0
    public let duration: TimeInterval

    public init(
        id: UUID = UUID(),
        sceneKey: GiftEffectSceneKey,
        imgUrl: String?,
        giftName: String,
        count: Int,
        duration: TimeInterval = 3.0
    ) {
        self.id = id
        self.sceneKey = sceneKey
        self.imgUrl = imgUrl
        self.giftName = giftName
        self.count = count
        self.duration = duration
    }
}
