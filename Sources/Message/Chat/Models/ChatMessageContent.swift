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

    // MARK: - 系统通知会话消息类型（对齐 H5 `views/news/message/systemMsg.vue`）

    /// CP 榜奖励到账 —— `attach.attachType == "CP_RANK_REWARD_NOTIFY"`
    /// - `rankNo`: 排名（rank.cp_rank_reward_msg 文案里的 %d）
    /// - `items`: 奖励道具列表 `[{itemIcon, itemName, itemType, quantity, durationDays}]`
    case cpRankReward(rankNo: Int, items: [CpRankRewardItem])

    /// 虚拟道具通知 —— `attach.attachType == "ITEM_GET_NOTICE" / "ITEM_EXPIRED_NOTICE"`
    case itemNotice(kind: ItemNoticeKind, itemName: String, itemType: Int, addTime: Int64?)

    /// 奖励下发（钻石到账）—— `ext.viewFlag == 8`
    /// 文案："Congratulations! You've received Diamond*{demoContent}"
    case rewardDiamond(demoContent: String)

    /// 惩罚申诉消息 —— `ext.penaltyUserId` 非空
    /// - `text`: 原 body（含 "click here" 关键字用于替换成可点链接）
    /// - `penaltyUserId`: 传给 `getPunishmentAppeal({userId:})` 的入参
    /// **isAppealed 由 view 层内存态维护**（H5 同款），不进 model。
    case punishmentAppeal(text: String, penaltyUserId: String)

    /// 用户充值成功通知 —— `attach.attachType == 35`
    /// - `content`: 原 attach.content 全文（含 "ID 12345" 用于替换成可点链接）
    /// - `targetUserId` / `targetYxAccId`: attach 里的目标用户信息（tap ID 跳详情用）
    case rechargeNotify(content: String, targetUserId: String?, targetYxAccId: String?)

    /// 兜底文本 —— attach 有 body/content 但 attachType 未识别（对齐 H5 v-else v-html body）
    /// 与 `.text` 语义不同（`.text` 是 NIM 原生 text 消息；此为 custom 消息兜底展示）
    case systemFallback(text: String)
}

/// CP 榜奖励卡片单个道具项。
struct CpRankRewardItem: Equatable, Hashable {
    let itemIcon: String?
    let itemName: String
    let itemType: Int      // 1 座驾 / 2 头像框 / 3 进场 / 4 聊天皮肤 / 5 卡片框 / 7 钻石 / 8 聊天卡
    let quantity: Int
    let durationDays: Int  // 时限型道具用（1-5 显示 × Nd）
}

/// 虚拟道具通知子类（对齐 H5 `ITEM_GET_NOTICE` / `ITEM_EXPIRED_NOTICE`）。
enum ItemNoticeKind: String, Equatable, Hashable {
    case get       // 收到（含 addTime 时长）
    case expired   // 过期
}

/// 未接来电子类（对齐 H5 `msgItem.vue`：status=null/undefined missed / 2 canceled / 3 rejected）
enum MissedCallKind: String, Equatable, Hashable {
    case missed
    case canceled
    case rejected
}
