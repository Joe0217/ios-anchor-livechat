import Foundation

/// 礼物消息载体（B 里程碑 spec §7.1）。
///
/// B 阶段仅用于公屏文本占位与 GiftAnimationQueueProtocol enqueue；
/// 真实动画播放（SVGA/MP4 队列、PK 期重排）归 H 里程碑 GiftAnimationPlayer。
struct GiftMessage: Equatable {
    let giftId: Int
    let giftName: String
    let giftCount: Int
    let diamond: Int
    let senderName: String
    let senderAvatar: URL?
    let receiverName: String?
    let attachType: AttachType
}
