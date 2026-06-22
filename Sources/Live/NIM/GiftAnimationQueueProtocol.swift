import Foundation

/// 礼物动画队列协议（B 里程碑 spec §7.3）。
///
/// B 阶段在 NIMChatroomManager 内 `weak` 持有但注入 nil，enqueue 调用空跑——
/// 公屏仅推文本占位。H 里程碑接入真实 `GiftAnimationPlayer` 承接 SVGA+MP4 队列。
protocol GiftAnimationQueueProtocol: AnyObject {
    func enqueue(_ gift: GiftMessage)
}
