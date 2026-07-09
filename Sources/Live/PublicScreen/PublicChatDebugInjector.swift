#if DEBUG
import Foundation

/// v19 DEBUG 公屏消息注入器 —— 一键注入所有 13 类 row 的 mock 消息
///
/// **用法**（LiveRoomView 加隐藏 tap）：
/// ```swift
/// #if DEBUG
/// .onTapGesture(count: 3) {
///     PublicChatDebugInjector.injectAll(into: nim.messagesStore)
/// }
/// #endif
/// ```
///
/// **触发**：真机进直播间 → 顶部空白区**三连击**注入全套 mock 消息，验证 13 类 row 视觉
enum PublicChatDebugInjector {
    // @MainActor：store.append(_:) 是 @MainActor 隔离方法；Xcode 16.1 严格并发下 nonisolated context 调用会报错
    @MainActor
    static func injectAll(into store: PublicChatMessagesStore) {
        let items: [PublicChatMessage] = [
            // 1. 主播消息
            PublicChatMessage(
                text: "Welcome to my live!",
                isSystem: false,
                senderNickname: "HostAnchor",
                senderAvatar: nil,
                userLevel: 50,
                isHost: true,
                isVip: false,
                messageType: .anchor
            ),
            // 2. 普通用户消息
            PublicChatMessage(
                text: "Hi anchor 👋",
                isSystem: false,
                senderNickname: "Alice",
                senderAvatar: nil,
                userLevel: 22,
                isHost: false,
                isVip: false,
                messageType: .regular
            ),
            // 3. VIP 用户消息
            PublicChatMessage(
                text: "Amazing show!",
                isSystem: false,
                senderNickname: "VipBob",
                senderAvatar: nil,
                userLevel: 45,
                isHost: false,
                isVip: true,
                messageType: .regular
            ),
            // 4. 用户进房
            PublicChatMessage(
                text: "",
                isSystem: false,
                senderNickname: "Charlie",
                senderAvatar: nil,
                userLevel: 15,
                isHost: false,
                isVip: false,
                messageType: .enterRoom
            ),
            // 5. 官方推荐进房（Official Boost）
            PublicChatMessage(
                text: "",
                isSystem: false,
                senderNickname: "OfficialUser",
                senderAvatar: nil,
                userLevel: 30,
                isHost: false,
                isVip: false,
                messageType: .officialBoostEnter
            ),
            // 6. 普通送礼
            PublicChatMessage(
                text: "",
                isSystem: false,
                senderNickname: "David",
                senderAvatar: nil,
                userLevel: 28,
                isHost: false,
                isVip: false,
                messageType: .gift(giftIconUrl: nil, giftName: "Rose", count: 3)
            ),
            // 7. 幸运礼物中奖（P0 用户明示）
            PublicChatMessage(
                text: "",
                isSystem: false,
                senderNickname: "LuckyEmma",
                senderAvatar: nil,
                userLevel: 40,
                isHost: false,
                isVip: true,
                messageType: .luckyGift(giftIconUrl: nil, count: 1, totalReward: 8888)
            ),
            // 8. PK 通知
            PublicChatMessage(
                text: "PK started against Opponent1",
                isSystem: true,
                senderNickname: nil,
                senderAvatar: nil,
                userLevel: nil,
                isHost: false,
                isVip: false,
                messageType: .pkNotify
            ),
            // 9. 猜拳获胜（P0 用户明示）
            PublicChatMessage(
                text: "",
                isSystem: false,
                senderNickname: "Frank",
                senderAvatar: nil,
                userLevel: 25,
                isHost: false,
                isVip: false,
                messageType: .rpsWin(medalUrl: nil, medalHours: 24)
            ),
            // 10. 转盘中奖
            PublicChatMessage(
                text: "10000 Coins",
                isSystem: false,
                senderNickname: "Grace",
                senderAvatar: nil,
                userLevel: 33,
                isHost: false,
                isVip: false,
                messageType: .wheelRes
            ),
            // 11. 直播公告（P1 用户明示）
            PublicChatMessage(
                text: "Welcome, this is a special promotion event!",
                isSystem: false,
                senderNickname: nil,
                senderAvatar: nil,
                userLevel: nil,
                isHost: false,
                isVip: false,
                messageType: .announcement
            ),
            // 12. 活动中奖广播
            PublicChatMessage(
                text: "",
                isSystem: false,
                senderNickname: "Henry",
                senderAvatar: nil,
                userLevel: nil,
                isHost: false,
                isVip: false,
                messageType: .winnerBroadcast(activityName: "Summer Fest 2026", quantity: 5)
            ),
            // 13. 心愿单登顶
            PublicChatMessage(
                text: "",
                isSystem: false,
                senderNickname: "IvyTop",
                senderAvatar: nil,
                userLevel: 45,
                isHost: false,
                isVip: false,
                messageType: .wishlistEffect
            ),
            // 14. 钻石盲盒 - 发包
            PublicChatMessage(
                text: "",
                isSystem: false,
                senderNickname: "SenderJack",
                senderAvatar: nil,
                userLevel: nil,
                isHost: false,
                isVip: false,
                messageType: .diamondGift(subType: .send(senderName: "SenderJack",
                                                          tierName: "GOLD",
                                                          totalDiamonds: 5000))
            ),
            // 15. 钻石盲盒 - 瓜分
            PublicChatMessage(
                text: "",
                isSystem: false,
                senderNickname: "ClaimerKim",
                senderAvatar: nil,
                userLevel: nil,
                isHost: false,
                isVip: false,
                messageType: .diamondGift(subType: .claim(userName: "ClaimerKim",
                                                           diamonds: 250))
            ),
        ]
        for it in items { store.append(it) }
    }
}
#endif
