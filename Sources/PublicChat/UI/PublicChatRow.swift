import SwiftUI

/// 单行分派：按 variant.discriminator 分 3 组 `@ViewBuilder`，
/// 避免 16 分支 switch 触发 SwiftUI type-check timeout（swiftui-body-type-check-timeout.md）
struct PublicChatRow: View {
    let message: UnifiedPublicChatMessage
    let theme: PublicChatTheme
    /// tap 翻译图标回调；non-nil 才在 `.text` variant + `sender?.isSelf == false` + `translation == nil` 时显示图标
    var onTapTranslate: ((UnifiedPublicChatMessage) -> Void)? = nil

    var body: some View {
        Group {
            switch message.variant.discriminator {
            case .text, .anchor, .gift, .luckyGift, .system:
                textGiftGroup
            case .enterRoom, .officialBoostEnter, .announcement, .pkNotify:
                notifyGroup
            case .rpsWin, .wheelRes, .winnerBroadcast, .wishlistEffect, .diamondGift:
                activityGroup
            case .gameWinNotify, .partyModeSwitch, .bonus:
                EmptyView()   // Phase 2/3 才 emit
            }
        }
    }

    @ViewBuilder private var textGiftGroup: some View {
        switch message.variant {
        case .text(let c, let mentions, let translation, let replyToNick):
            // 翻译图标只对"别人发的 + 未翻译"消息显示（对齐 H5 `!item.isSelf` + `!item.isShow`）
            let showTranslate = (message.sender?.isSelf == false) && translation == nil && onTapTranslate != nil
            RowRegularText(
                sender: message.sender, content: c, mentions: mentions,
                translation: translation, replyToNick: replyToNick, theme: theme,
                onTapTranslate: showTranslate ? { onTapTranslate?(message) } : nil
            )
        case .anchor(let c, let translation):
            RowAnchor(sender: message.sender, content: c, translation: translation, theme: theme)
        case .gift(let url, let name, let count):
            RowGift(sender: message.sender, iconURL: url, name: name, count: count, theme: theme)
        case .luckyGift(let url, let count, let total):
            RowLuckyGift(sender: message.sender, iconURL: url, count: count, totalReward: total, theme: theme)
        case .system(let text):
            RowAnnouncement(text: text, kind: .liveOfficial, theme: theme)   // 兜底沿用 announcement 视觉
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var notifyGroup: some View {
        switch message.variant {
        case .enterRoom(let vehicle, let item):
            RowEnterRoom(sender: message.sender, vehicleImg: vehicle, itemSmallImg: item, theme: theme)
        case .officialBoostEnter:
            RowOfficialBoostEnter(sender: message.sender, theme: theme)
        case .announcement(let text, let kind):
            RowAnnouncement(text: text, kind: kind, theme: theme)
        case .pkNotify(let rt):
            RowPKNotify(richText: rt, theme: theme)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var activityGroup: some View {
        switch message.variant {
        case .rpsWin(let url, let hours):
            RowRpsWin(sender: message.sender, medalUrl: url, medalHours: hours, theme: theme)
        case .wheelRes(let text, let hl):
            RowWheelRes(sender: message.sender, resultText: text, resultHighlight: hl, theme: theme)
        case .winnerBroadcast(let name, let qty, let img, let cta, let avatar):
            RowWinnerBroadcast(activityName: name, quantity: qty, imageURL: img,
                               joinCTA: cta, avatar: avatar, theme: theme)
        case .wishlistEffect(let text, let icon):
            RowWishlistEffect(text: text, iconURL: icon, theme: theme)
        case .diamondGift(let sub):
            RowDiamondGift(subType: sub, theme: theme)
        default:
            EmptyView()
        }
    }
}
