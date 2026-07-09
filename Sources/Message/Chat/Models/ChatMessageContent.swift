import Foundation

/// P2P 私聊消息内容（H-2 spec §2.4；系统消息扩展见 H5 `chat/components/msgItem.vue`）。
///
/// **iOS 展示分类**：
/// - text / image / video / audio：常规消息 bubble
/// - systemGift / missedCall：Custom attachType 特化 bubble
/// - systemTip：weakTxtType 数字提示（居中灰字条）
/// - system(rawJSON:)：兜底占位，保 SDK 原 attach 便于 H-3+ 分发扩展
///
/// **注**：`previewText` L10n 派生放在 `ChatMessageContent+Preview.swift`
enum ChatMessageContent: Equatable, Hashable {
    case text(String)
    case image(url: URL, size: CGSize?)
    case video(url: URL, thumbnail: URL?, dur: Int)   // dur 秒
    case audio(url: URL, dur: Int)                    // dur 秒

    /// SEND_GIFT 礼物消息（对齐 H5 `msgItem.vue:272-288`）
    case systemGift(smallImg: URL?, giftNum: Int)

    /// MISSED_CALLS_RECORD 未接/取消/拒接来电（对齐 H5 `msgItem.vue:297-314`）
    case missedCall(kind: MissedCallKind)

    /// weakTxtType 系统提示（-4 关注 / 103/104 裂变 / 156/157 活动等；居中灰字条）
    /// **weakType**：保留原 attachType 数字便于将来分文案国际化
    case systemTip(text: String, weakType: Int)

    /// 兜底：保 SDK 原 attach raw JSON，不识别的 attachType 走这里（H-3+ 补分发）
    case system(rawJSON: String)

    // MARK: - H-3 新增（spec §2.1 / §3.2 / §1.1）

    /// 私密图片消息（对齐 H5 `msgItem.vue:234-241`）。
    /// - NIM msg.type 是标准 `image`（非 custom）；私密标识在 `remoteExt.extensionType == "privateMsg"`
    /// - lockStatus 来自 `checkPrivateInfo` 拉取；主播端**只读展示 icon**，不参与扣费
    case privateImage(url: URL, lockStatus: PrivateLockStatus)

    /// 私密视频消息（同上；视频播放走 `GiftMessageService.decryptVideoUrl`）
    case privateVideo(url: URL, coverUrl: URL?, dur: Int, lockStatus: PrivateLockStatus)

    /// 回复积分 tip（H-3 spec §2.5）。tip 与真实消息按 `stableSortKey` 混合排序；
    /// **不进 pendingBottomBadge 未读计数**（对齐 §F-40）。
    case chatTip(kind: ChatTipKind, text: String, tipTs: Int64)
}

/// 未接来电子类（对齐 H5 `msgItem.vue`：status=null/undefined missed / 2 canceled / 3 rejected）
enum MissedCallKind: String, Equatable, Hashable {
    case missed
    case canceled
    case rejected
}
