import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "GiftEffectIntake")

/// 4 场景 IM 消息统一入队入口
///
/// 职责：从 NIM 消息 payload dict 构造 GiftEffectItem →
///       判定"有动画资源走中央大动画 vs 无动画走 MicroToast"→
///       dispatch 到 GiftEffectCenter
///
/// 特例规则：Chat 场景**无**动画资源时不启用 MicroToast（消息气泡由 SystemGiftBubbleView 承担）
@MainActor
public enum GiftEffectIntake {

    /// - Returns: true 表示识别为有效礼物消息（无论走队列还是 MicroToast）；false 表示 payload 缺关键字段
    @discardableResult
    public static func ingest(
        scene: GiftEffectScene,
        scopeId: String,
        payload: [String: Any],
        mineYxAccid: String,
        into center: GiftEffectCenter = .shared
    ) -> Bool {
        let key = GiftEffectSceneKey(scene: scene, scopeId: scopeId)
        guard let item = GiftEffectPayloadDecoder.decode(
            sceneKey: key, payload: payload, mineYxAccid: mineYxAccid
        ) else {
            logger.warning("intake failed: no valid giftId in payload; scene=\(scene.rawValue, privacy: .public)")
            return false
        }

        if item.animationUrl != nil {
            // 有动画资源 → 中央大动画
            center.enqueue(item)
        } else if scene != .chat {
            // 无动画资源 + 非 Chat → 底部 MicroToast
            let toast = MicroToastItem(
                sceneKey: key,
                imgUrl: item.staticImgUrl,
                giftName: item.giftName,
                count: item.giftCount
            )
            center.showMicroToast(toast)
        }
        // Chat + 无动画：不做任何 UI（SystemGiftBubbleView 已承担消息气泡）
        return true
    }
}
