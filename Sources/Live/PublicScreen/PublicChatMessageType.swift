import Foundation

/// v18 公屏消息类型完整分类（对齐 H5 messageScroller.vue 全部 v-if/v-else-if 分支）
///
/// **H5 分派链**（stores/modules/live.js handleCustomMessage / handleLiveGiftMessage / handleNotificationMessage）：
/// - anchor: 主播消息（紫色渐变 + 粉昵称 #FE00DE + host icon）
/// - regular: 普通用户文本（rgba(0,0,0,0.16) + 青绿昵称 #1AFFCD）
/// - gift: 送礼（attachType 1 无 totalReward，rgba(0,0,0,0.16)）
/// - luckyGift: 幸运礼物（attachType 1 有 totalReward，粉→黄渐变 h50）
/// - enterRoom: 用户进房（notification/memberEnter，含 inLiveChannel/vehicleImg）
/// - officialBoostEnter: 官方推荐进房（enterRoom + inLiveChannel===1，蓝色渐变）
/// - pkNotify: PK 通知（attachType -9，暗红 + 富文本）
/// - rpsWin: 猜拳获胜（attachType 144，紫渐变 + 黄昵称 + medal）
/// - wheelRes: 转盘结果（橙色 + 亮黄结果 #FFED68）
/// - announcement: 直播公告（attachType 195，蓝紫 + 📢）
/// - winnerBroadcast: 活动中奖（attachType 140，跑马灯或大卡）
/// - wishlistEffect: 心愿单登顶（attachType 251）
/// - diamondGift: 钻石盲盒（attachType 1030/1032/1033，4 subType）
enum PublicChatMessageType: Equatable {
    case anchor
    case regular
    /// 送礼消息（无幸运奖池）
    case gift(giftIconUrl: String?, giftName: String, count: Int)
    /// v18 幸运礼物中奖（送礼时中大奖）—— 对齐 H5 L474-484 lucky-gift-box
    case luckyGift(giftIconUrl: String?, count: Int, totalReward: Int64)
    case enterRoom
    /// v18 官方推荐进房（inLiveChannel===1，对齐 H5 L595）
    case officialBoostEnter
    case pkNotify
    /// v18 猜拳获胜（attachType 144）—— medalUrl + medalHours 完整字段
    case rpsWin(medalUrl: String?, medalHours: Int?)
    case wheelRes
    case announcement
    /// v18 活动中奖广播（attachType 140）
    case winnerBroadcast(activityName: String, quantity: Int?)
    /// v18 心愿单 TOP1 登顶（attachType 251）
    case wishlistEffect
    /// v18 钻石盲盒 4 子类型（attachType 1030/1032/1033）
    case diamondGift(subType: DiamondGiftSubType)

    /// 简化 discriminator，供 dispatch 使用
    var discriminator: Discriminator {
        switch self {
        case .anchor: return .anchor
        case .regular: return .regular
        case .gift: return .gift
        case .luckyGift: return .luckyGift
        case .enterRoom: return .enterRoom
        case .officialBoostEnter: return .officialBoostEnter
        case .pkNotify: return .pkNotify
        case .rpsWin: return .rpsWin
        case .wheelRes: return .wheelRes
        case .announcement: return .announcement
        case .winnerBroadcast: return .winnerBroadcast
        case .wishlistEffect: return .wishlistEffect
        case .diamondGift: return .diamondGift
        }
    }

    enum Discriminator {
        case anchor, regular, gift, luckyGift, enterRoom, officialBoostEnter,
             pkNotify, rpsWin, wheelRes, announcement,
             winnerBroadcast, wishlistEffect, diamondGift
    }
}

/// v18 钻石盲盒 4 子类型（对齐 H5 attachType 1030/1032/1033）
enum DiamondGiftSubType: Equatable {
    /// 1030 发包
    case send(senderName: String, tierName: String?, totalDiamonds: Int64)
    /// 1032 瓜分
    case claim(userName: String, diamonds: Int64)
    /// 1033 结算（TOP 分享）
    case settled(topUserName: String, topDiamonds: Int64)
    /// 1033 过期退回
    case expired(senderName: String, refundDiamonds: Int64)
}
