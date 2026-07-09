import Foundation

/// 礼物特效所在的业务场景
public enum GiftEffectScene: String, Hashable, Sendable {
    case live
    case call
    case party
    case chat
}

/// 礼物特效队列的作用域 key（scene + scopeId 唯一确定一条队列）
///
/// scopeId 示例：直播用 liveRoomId，通话用 callId，派对用 partyRoomId
public struct GiftEffectSceneKey: Hashable, Sendable {
    public let scene: GiftEffectScene
    public let scopeId: String

    public init(scene: GiftEffectScene, scopeId: String) {
        self.scene = scene
        self.scopeId = scopeId
    }
}
