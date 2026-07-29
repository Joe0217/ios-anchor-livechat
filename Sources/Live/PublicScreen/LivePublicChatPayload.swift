import Foundation

/// 公屏一条消息（v8 扩展：对齐 H5 messageScroller.vue 结构化字段）。
///
/// **v22 Phase 1**：从 `NIMChatroomManager.swift` 抽出到独立文件（Phase 1 T8），
/// 方便 `LivePublicChatAdapter` 单元测试进入 HilyTests 白名单（NIMChatroomManager 依赖 NIMSDK 不入白名单）。
///
/// Phase 1 内 adapter 直接读 `messageType` 派 `PublicChatVariant`；结构无 breaking change。
struct PublicChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isSystem: Bool
    // v8 结构化扩展（可选，向后兼容旧构造点）
    let senderNickname: String?
    let senderAvatar: String?
    let userLevel: Int?
    let isHost: Bool
    let isVip: Bool
    let messageType: PublicChatMessageType
    /// v22（2026-07-10）：座驾图 URL（enterRoom / officialBoostEnter 场景专用）
    let itemSmallImg: String?
    /// v24（B1 活跃大R）：大 R 徽章 + enterRoom 金色底
    let isActiveTycoon: Bool
    /// v24（B4 hi 气泡）：云信 fromAccid，MSG 半屏私聊时开对方 P2P 会话用
    let senderYxAccId: String?
    /// v24（B4 hi 气泡）：ext.userId，未来 @mention/名片卡定位用；String/Int 双兼容 decode 后统一 String
    let senderUserId: String?
    /// v24（B4 hi 气泡）：主播 @ 回复的对方昵称（ext.replyNick），非 nil 时公屏 anchor row 渲染 @ 格式
    let replyToNick: String?
    /// v24（B4 hi 气泡）：`fromAccid == self yxAccid`，主播自发消息不弹 hi 气泡
    let isSelf: Bool
    /// H5 新人标识：普通文本和礼物行展示新人标。
    let isNewUser: Bool
    /// 守护等级。0 表示无守护，正数显示守护徽章。
    let guardianLevel: Int
    /// 发送方穿戴的点九图气泡背景。
    let chatBubble: String?
    /// 中奖广播点击目标活动地址；只由对应 Row 消费。
    let actionURL: String?
    /// 中奖广播的大图背景与 Join 图。
    let winnerMessageImageURL: String?
    let winnerJoinImageURL: String?
    /// 中奖广播内嵌奖品图标、有效天数与颜色配置。
    let winnerPrizeImageURL: String?
    let winnerValidDays: Int?
    let winnerNicknameColorHex: String?
    let winnerPrizeColorHex: String?
    let winnerCardType: String?

    init(text: String,
         isSystem: Bool,
         senderNickname: String? = nil,
         senderAvatar: String? = nil,
         userLevel: Int? = nil,
         isHost: Bool = false,
         isVip: Bool = false,
         messageType: PublicChatMessageType = .regular,
         itemSmallImg: String? = nil,
         isActiveTycoon: Bool = false,
         senderYxAccId: String? = nil,
         senderUserId: String? = nil,
         replyToNick: String? = nil,
         isSelf: Bool = false,
         isNewUser: Bool = false,
         guardianLevel: Int = 0,
         chatBubble: String? = nil,
         actionURL: String? = nil,
         winnerMessageImageURL: String? = nil,
         winnerJoinImageURL: String? = nil,
         winnerPrizeImageURL: String? = nil,
         winnerValidDays: Int? = nil,
         winnerNicknameColorHex: String? = nil,
         winnerPrizeColorHex: String? = nil,
         winnerCardType: String? = nil) {
        self.text = text
        self.isSystem = isSystem
        self.senderNickname = senderNickname
        self.senderAvatar = senderAvatar
        self.userLevel = userLevel
        self.isHost = isHost
        self.isVip = isVip
        self.messageType = messageType
        self.itemSmallImg = itemSmallImg
        self.isActiveTycoon = isActiveTycoon
        self.senderYxAccId = senderYxAccId
        self.senderUserId = senderUserId
        self.replyToNick = replyToNick
        self.isSelf = isSelf
        self.isNewUser = isNewUser
        self.guardianLevel = guardianLevel
        self.chatBubble = chatBubble
        self.actionURL = actionURL
        self.winnerMessageImageURL = winnerMessageImageURL
        self.winnerJoinImageURL = winnerJoinImageURL
        self.winnerPrizeImageURL = winnerPrizeImageURL
        self.winnerValidDays = winnerValidDays
        self.winnerNicknameColorHex = winnerNicknameColorHex
        self.winnerPrizeColorHex = winnerPrizeColorHex
        self.winnerCardType = winnerCardType
    }
}
