import SwiftUI

/// 让气泡按内容宽度收紧；长文本才使用调用方给定的最大宽度换行。
///
/// 普通 `frame(maxWidth:)` 在父容器提供明确宽度时会扩展至上限，带 Divider 的译文气泡尤其明显。
/// 这个 layout 先以无约束尺寸确定内容宽度，再以既有最大宽度约束长文本。
struct PublicChatContentHuggingLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let availableWidth = min(proposal.width ?? maxWidth, maxWidth)
        let intrinsic = subview.sizeThatFits(.unspecified)
        let width = min(intrinsic.width, availableWidth)
        let fitted = subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: width, height: fitted.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        for subview in subviews {
            subview.place(
                at: bounds.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
            )
        }
    }
}

/// 单行分派：按 variant.discriminator 分 3 组 `@ViewBuilder`，
/// 避免 16 分支 switch 触发 SwiftUI type-check timeout（swiftui-body-type-check-timeout.md）
///
/// **v3（2026-07-15）Party 场景对齐 H5 用户端 chat-list.vue 布局**：
/// - `.text` / `.gift` variant 在 `theme.scene == .party` 时走带头像的多行布局（`RowPartyRegularText` / `RowPartyGift` 见文件底部）
/// - `.partyModeSwitch` / `.gameWinNotify` 从 EmptyView 升级为具体渲染
///
/// Party 专用 Row 定义**内联在本文件底部**（避免新 .swift 文件需 xcodegen regen；未来 regen 后可拆出）。
struct PublicChatRow: View {
    let message: UnifiedPublicChatMessage
    let theme: PublicChatTheme
    /// tap 翻译图标回调；non-nil 才在 `.text` variant + `sender?.isSelf == false` + `translation == nil` 时显示图标
    var onTapTranslate: ((UnifiedPublicChatMessage) -> Void)? = nil
    /// 翻译进行中(pendingTranslateIds.contains(id) 派生)。true 时图标切换为沙漏,tap 禁重触发
    var isTranslating: Bool = false
    /// v24（B4 · 对齐 H5 §9.12.4 hi 气泡）：tap hi 图标回调
    /// 门控：仅 `.text` variant + `sender?.isSelf == false` + `theme.scene == .live` 时传给 Row
    /// （PublicChatListView 层收敛 popover state）
    var onTapHi: ((UnifiedPublicChatMessage) -> Void)? = nil
    /// 公屏发送者昵称点击。所有可解析 userId（包括当前登录主播）均可拉起名片卡。
    var onTapUserCard: ((String) -> Void)? = nil
    /// 活动中奖广播点击。
    var onWinnerActivity: ((String) -> Void)? = nil
    /// 钻石福袋结算卡点击，主播端据此打开获奖名单。
    var onTapDiamondGiftSettled: ((Int64) -> Void)? = nil
    /// Party 审核账号的极简公屏发送者样式。
    var usesPlainPartySenderStyle: Bool = false

    var body: some View {
        Group {
            switch message.variant.discriminator {
            case .text, .anchor, .gift, .luckyGift, .firstGiftMoment, .partyLuckyNumber, .system:
                textGiftGroup
            case .enterRoom, .officialBoostEnter, .announcement, .pkNotify, .pkTopContributors, .partyModeSwitch, .partyBattle:
                notifyGroup
            case .rpsWin, .wheelRes, .winnerBroadcast, .wishlistEffect, .diamondGift, .gameWinNotify:
                activityGroup
            case .bonus:
                EmptyView()   // Live 场景 · Phase 2 才 emit
            }
        }
    }

    @ViewBuilder private var textGiftGroup: some View {
        switch message.variant {
        case .text(let c, let mentions, let translation, let replyToNick):
            let showTranslate = (message.sender?.isSelf == false) && translation == nil && onTapTranslate != nil
            // v24（B4）：hi 图标门控 —— 仅 Live 场景 + 非自己发送 + caller 提供回调
            let showHi = (message.sender?.isSelf == false) && theme.scene == .live && onTapHi != nil
            if theme.scene == .party {
                RowPartyRegularText(
                    sender: message.sender, content: c, mentions: mentions,
                    translation: translation, replyToNick: replyToNick,
                    onTapTranslate: showTranslate ? { onTapTranslate?(message) } : nil,
                    isTranslating: isTranslating,
                    onTapNickname: senderCardAction,
                    usesPlainSenderStyle: usesPlainPartySenderStyle
                )
            } else {
                RowRegularText(
                    sender: message.sender, content: c, mentions: mentions,
                    translation: translation, replyToNick: replyToNick, theme: theme,
                    onTapTranslate: showTranslate ? { onTapTranslate?(message) } : nil,
                    isTranslating: isTranslating,
                    onTapHi: showHi ? { onTapHi?(message) } : nil,
                    onTapNickname: senderCardAction
                )
            }
        case .anchor(let c, let translation):
            RowAnchor(sender: message.sender, content: c, translation: translation, theme: theme,
                      onTapNickname: senderCardAction)
        case .gift(let url, let name, let count, let recipients):
            if theme.scene == .party {
                RowPartyGift(sender: message.sender, iconURL: url, name: name, count: count, recipients: recipients,
                             onTapNickname: senderCardAction, onTapUserCard: onTapUserCard)
            } else {
                RowGift(sender: message.sender, iconURL: url, name: name, count: count, theme: theme,
                        onTapNickname: senderCardAction)
            }
        case .luckyGift(let url, let count, let total):
            RowLuckyGift(sender: message.sender, iconURL: url, count: count, totalReward: total, theme: theme,
                         onTapNickname: senderCardAction)
        case .firstGiftMoment(let backgroundURL, let renderedText, let giftIconURL, let isFirstGift):
            RowFirstGiftMoment(
                sender: message.sender,
                backgroundURL: backgroundURL,
                renderedText: renderedText,
                giftIconURL: giftIconURL,
                isFirstGift: isFirstGift,
                onTapNickname: senderCardAction
            )
        case .partyLuckyNumber(let number, let didWin):
            RowPartyLuckyNumber(sender: message.sender, number: number, didWin: didWin,
                                onTapNickname: senderCardAction)
        case .system(let text):
            RowAnnouncement(text: text, kind: theme.scene == .party ? .partyRoom : .liveOfficial, theme: theme)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var notifyGroup: some View {
        switch message.variant {
        case .enterRoom(let vehicle, let item):
            RowEnterRoom(sender: message.sender, vehicleImg: vehicle, itemSmallImg: item, theme: theme,
                         onTapNickname: senderCardAction)
        case .officialBoostEnter:
            RowOfficialBoostEnter(sender: message.sender, theme: theme, onTapNickname: senderCardAction)
        case .announcement(let text, let kind):
            RowAnnouncement(text: text, kind: kind, theme: theme)
        case .pkNotify(let rt):
            RowPKNotify(richText: rt, theme: theme)
        case .pkTopContributors(let users):
            RowPKTopContributors(
                users: users,
                onTapNickname: theme.scene == .live || theme.scene == .party ? onTapUserCard : nil
            )
        case .partyModeSwitch(let text, _):
            // v3：Party 房系统消息（切模板 / 排麦开关 / 房管变更 / 视频位邀请接受）居中卡片，无头像
            RowPartyModeSwitch(text: text)
        case .partyBattle(_, let text, let highlight):
            // Party 房 PK 系统消息（对齐 H5 chat-list.vue :333-392 · PK icon + 半透黑底 + 黄色高亮）
            RowPartyBattle(text: text, highlight: highlight)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var activityGroup: some View {
        switch message.variant {
        case .rpsWin(let url, let hours, let gameType):
            RowRpsWin(sender: message.sender, medalUrl: url, medalHours: hours,
                      gameType: gameType, theme: theme, onTapNickname: senderCardAction)
        case .wheelRes(let text, let hl):
            RowWheelRes(sender: message.sender, resultText: text, resultHighlight: hl, theme: theme,
                        onTapNickname: senderCardAction)
        case .winnerBroadcast(let name, let qty, let messageImageURL, let prizeImageURL, let cta,
                              let avatar, let validDays, let nicknameColorHex, let prizeColorHex, let cardType):
            RowWinnerBroadcast(
                sender: message.sender,
                activityName: name,
                quantity: qty,
                messageImageURL: messageImageURL,
                prizeImageURL: prizeImageURL,
                joinCTA: cta,
                avatar: avatar,
                validDays: validDays,
                nicknameColorHex: nicknameColorHex,
                prizeColorHex: prizeColorHex,
                cardType: cardType,
                theme: theme,
                onTapNickname: senderCardAction,
                onTap: message.actionURL.flatMap { url in
                    onWinnerActivity.map { callback in { callback(url) } }
                }
            )
        case .wishlistEffect:
            RowWishlistEffect(sender: message.sender, onTapNickname: senderCardAction)
        case .diamondGift(let sub):
            RowDiamondGift(
                subType: sub,
                theme: theme,
                onTapNickname: senderCardAction,
                onTapSettled: onTapDiamondGiftSettled
            )
        case .gameWinNotify(let payload):
            // v3：全服/本房游戏中奖公屏（对齐 H5 game-win-public-msg.vue）
            RowGameWinNotify(
                payload: payload,
                theme: theme,
                onTapNickname: userCardAction(userId: payload.userId)
            )
        default:
            EmptyView()
        }
    }

    private var senderCardAction: (() -> Void)? {
        guard let sender = message.sender else { return nil }
        return userCardAction(userId: sender.userId)
    }

    private func userCardAction(userId: String?) -> (() -> Void)? {
        guard theme.scene == .live || theme.scene == .party,
              let userId,
              !userId.isEmpty,
              let onTapUserCard else { return nil }
        return { onTapUserCard(userId) }
    }
}

// MARK: - Party 场景专用 Row（内联避免新文件 pbxproj regen 依赖；未来 regen 后可拆出）

/// Party 常规文字（对齐 H5 chat-list.vue L138-181：头像 32x32 + 昵称行 + 气泡下方）
private struct RowPartyRegularText: View {
    let sender: SenderProfile?
    let content: String
    let mentions: [Mention]
    let translation: String?
    let replyToNick: String?
    let onTapTranslate: (() -> Void)?
    let isTranslating: Bool
    let onTapNickname: (() -> Void)?
    let usesPlainSenderStyle: Bool

    var body: some View {
        if usesPlainSenderStyle {
            plainBody
        } else {
            decoratedBody
        }
    }

    private var decoratedBody: some View {
        HStack(alignment: .top, spacing: 8) {
            // v4 动态尺寸：无头像框时头像充满 32pt（否则头像内 24pt 视觉过小）；有头像框时头像 24pt 框外扩 32pt
            PartyAvatarWithFrame(
                avatarURL: sender?.avatarURL,
                headFrame: sender?.headFrame,
                userId: sender?.userId
            )
            VStack(alignment: .leading, spacing: 6) {
                PartyNicknameRow(sender: sender, onTapNickname: onTapNickname)
                bubbleBody
            }
        }
    }

    /// 107 公屏：普通头像 + 昵称 + 正文。保留昵称点击打开名片卡，但不加载头像框或其他装饰资源。
    @ViewBuilder
    private var plainBody: some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarView(
                urlString: sender?.avatarURL,
                size: 32,
                kind: .user,
                userId: sender?.userId
            )
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            if let onTapNickname {
                Button(action: onTapNickname) {
                    plainText
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(sender?.nickname ?? ""))
            } else {
                plainText
            }
        }
    }

    private var plainText: Text {
        var result = Text("\(sender?.nickname ?? ""): ")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
        if let mention = mentions.first {
            result = result + Text("@\(mention.userName) ")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
        }
        return result + Text(content)
            .font(.system(size: 13))
            .foregroundColor(.white)
    }

    private var bubbleBody: some View {
        let showTranslate = translation == nil && onTapTranslate != nil
        let hasChatSkin = sender?.chatBubble?.isEmpty == false
        return PublicChatContentHuggingLayout(maxWidth: 213) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 4) {
                    bodyText(showTranslate: showTranslate)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let translation, !translation.isEmpty {
                    Divider().overlay(Color.white.opacity(0.16))
                    Text(translation)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, hasChatSkin ? ChatSkinMetrics.horizontalContentInset : 8)
            .padding(.vertical, hasChatSkin ? ChatSkinMetrics.verticalContentInset : 4)
            .frame(minHeight: 22)
            .background(bubbleBackground)
            .padding(.vertical, hasChatSkin ? ChatSkinMetrics.messageVerticalSpacing : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if showTranslate && !isTranslating { onTapTranslate?() }
        }
        .accessibilityAddTraits(showTranslate ? .isButton : [])
    }

    private func bodyText(showTranslate: Bool) -> Text {
        var result: Text = Text("")
        if let m = mentions.first {
            result = result + Text("@\(m.userName) ")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(red: 231/255, green: 84/255, blue: 2/255))  // #E75402
        }
        result = result + Text(content)
            .font(.system(size: 13))
            .foregroundColor(.white)
        if showTranslate {
            let iconName = isTranslating ? "hourglass" : "character.book.closed.fill"
            let iconColor: Color = isTranslating
                ? Color.white.opacity(0.5)
                : Color(red: 196/255, green: 155/255, blue: 1.0)  // #C49BFF
            let iconText = Text(" ") + Text(Image(systemName: iconName))
                .font(.system(size: 13))
                .foregroundColor(iconColor)
            result = result + iconText
        }
        return result
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if let raw = sender?.chatBubble, let url = URL(string: raw), !raw.isEmpty {
            NinePatchImageView(url: url)
        } else {
            RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.30))
        }
    }
}

/// Party 送礼消息（对齐 H5 chat-list.vue L183-204：头像 + 昵称行 + Sends to 气泡）
private struct RowPartyGift: View {
    let sender: SenderProfile?
    let iconURL: String?
    let name: String
    let count: Int
    let recipients: [PublicChatGiftRecipient]
    let onTapNickname: (() -> Void)?
    let onTapUserCard: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PartyAvatarWithFrame(
                avatarURL: sender?.avatarURL,
                headFrame: sender?.headFrame,
                userId: sender?.userId
            )
            VStack(alignment: .leading, spacing: 6) {
                PartyNicknameRow(sender: sender, onTapNickname: onTapNickname)
                giftBubble
            }
        }
    }

    private var giftBubble: some View {
        PartyGiftFlowLayout(spacing: 4, lineSpacing: 4) {
            Text("Sends to")
                .font(.system(size: 13))
                .foregroundColor(.white)
            recipientDisplay
            giftDisplay
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 256, minHeight: 44, alignment: .leading)
        .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var recipientDisplay: some View {
        if recipients.count == 1 {
            let recipient = recipients[0]
            let label = Text(recipient.nickname ?? "")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(red: 26/255, green: 1.0, blue: 205/255))
            if let userId = recipient.userId, !userId.isEmpty, let onTapUserCard {
                Button(action: { onTapUserCard(userId) }) { label }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(recipient.nickname ?? ""))
            } else {
                label
            }
        } else {
            HStack(spacing: 4) {
                HStack(spacing: -4) {
                    ForEach(Array(recipients.prefix(3).enumerated()), id: \.offset) { _, recipient in
                        AvatarView(
                            urlString: recipient.avatarURL,
                            size: 20,
                            kind: .user,
                            persistent: true,
                            disablesTap: true
                        )
                        .overlay(Circle().stroke(Color.black.opacity(0.30), lineWidth: 1))
                    }
                }
                Text("\(recipients.count) persons")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(red: 26/255, green: 1.0, blue: 205/255))
            }
        }
    }

    private var giftDisplay: some View {
        HStack(spacing: 4) {
            CachedAsyncImage(url: URL(string: iconURL ?? ""), contentMode: .fill, cdn: (.gift, .fit)) {
                Image(systemName: "gift.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.08))
            }
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text("x\(count * recipients.count)")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .monospacedDigit()
        }
    }
}

/// H5 礼物气泡使用 flex-wrap；iOS 这里按相同规则让收礼人和礼物组在宽度不足时换行。
private struct PartyGiftFlowLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maximumWidth = proposal.width ?? .greatestFiniteMagnitude
        let rows = rows(for: subviews, maximumWidth: maximumWidth)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * lineSpacing
        return CGSize(width: min(width, maximumWidth), height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = rows(for: subviews, maximumWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let view = subviews[index]
                let size = view.sizeThatFits(.unspecified)
                view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func rows(for subviews: Subviews, maximumWidth: CGFloat) -> [Row] {
        var result: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposedWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, proposedWidth > maximumWidth {
                result.append(current)
                current = Row()
            }
            current.indices.append(index)
            current.width = current.indices.count == 1 ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { result.append(current) }
        return result
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
}

/// Party 系统消息（切模板 / 排麦开关 / 房管变更 / 视频位邀请接受）—— 无头像，占用全宽。
/// v3+（2026-07-16）：**取消头像空间预留**，与 [RowAnnouncement](Rows/RowAnnouncement.swift) 公告布局一致
/// 从左边缘起 —— 用户反馈"切换 party 房背景图的消息宽度要像公告一样"
private struct RowPartyModeSwitch: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(.white)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 288, alignment: .leading)   // 与 announcement 249 + gameWin 280 同档
            .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Party 房幸运数字公屏（1050 抽数 / 1051 中奖）。
/// 对齐 H5 `chat-list.vue`：复用普通用户的头像、昵称、等级、VIP、勋章与角色头部，
/// 抽数显示 "Lucky number: N"，中奖额外显示成功文案。
private struct RowPartyLuckyNumber: View {
    let sender: SenderProfile?
    let number: Int
    let didWin: Bool
    let onTapNickname: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PartyAvatarWithFrame(
                avatarURL: sender?.avatarURL,
                headFrame: sender?.headFrame,
                userId: sender?.userId
            )
            VStack(alignment: .leading, spacing: 6) {
                PartyNicknameRow(sender: sender, onTapNickname: onTapNickname)
                VStack(alignment: .leading, spacing: didWin ? 6 : 0) {
                    HStack(alignment: .center, spacing: 6) {
                        CachedAsyncImage(
                            url: URL(string: "https://file.lovetravel.link/mstatic/lucky-num/lucky-num-icon.webp"),
                            contentMode: .fit,
                            persistent: true
                        ) {
                            Image(systemName: "number.circle.fill")
                                .resizable()
                                .scaledToFit()
                                .foregroundColor(Color(red: 1.0, green: 0.83, blue: 0.34))
                        }
                        .frame(width: 26, height: 26)
                        .accessibilityHidden(true)

                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(L10n.PartyRoom.toolMenuLuckyNumber + ":")
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                            // H5 is 18px; the iOS requirement increases the previous 13pt value by 6pt.
                            LuckyNumberGradientText(value: "\(number)", fontSize: 19)
                        }
                    }
                    if didWin {
                        Text(L10n.Party.luckyNumberMatched)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: 213, alignment: .leading)
                .background(Color.black.opacity(0.40), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

/// Shared with Party Lucky Number history and win surfaces.
/// Matches H5 `.lucky-number-value`: `#FCF2DC -> #FDD481`, 270 degrees.
struct LuckyNumberGradientText: View {
    let value: String
    let fontSize: CGFloat
    var weight: Font.Weight = .medium

    var body: some View {
        Text(value)
            .font(.system(size: fontSize, weight: weight))
            .monospacedDigit()
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        Color(red: 252 / 255, green: 242 / 255, blue: 220 / 255),
                        Color(red: 253 / 255, green: 212 / 255, blue: 129 / 255),
                    ],
                    startPoint: .trailing,
                    endPoint: .leading
                )
            )
            .environment(\.layoutDirection, .leftToRight)
    }
}

/// Party 房 Battle Team PK 系统消息（对齐 H5 chat-list.vue :333-392 完整视觉）
///
/// 视觉结构（H5 4 kind 完全一致）：
/// - 左侧 32×32 PK 图标（与顶部进度条两侧的 `PK` 标识一致）
/// - 右侧半透黑底 rounded-12 卡（`bg-#000/30 px-8 py-4`）
/// - 13pt 文字，白色 + 关键数字/名字用 #FFE600 黄色高亮
private struct RowPartyBattle: View {
    let text: String
    /// 高亮数字/名字（对齐 H5 `<span class="mx-2 c-#FFE600">{{ N }}</span>`）
    /// - 非 nil：文本中若含 `{highlight}` 占位符则替换为黄色片段；否则拼在末尾
    /// - nil：整段白色（如 forceEnd 无高亮）
    let highlight: String?

    private static let highlightColor = Color(red: 1.0, green: 0.9, blue: 0.0)  // #FFE600

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            CDNAssetImage("partyPkLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .frame(width: 32, height: 32)

            // 半透黑底 rounded-12 卡（H5 max-w-213 min-h-22 rounded-12 bg-#000/30 px-8 py-4）
            Group {
                if let hl = highlight, !hl.isEmpty {
                    combinedText(hl)
                } else {
                    Text(text)
                        .foregroundColor(.white)
                }
            }
            .font(.system(size: 13))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 240, alignment: .leading)
            .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// 高亮拼接：若 text 含占位符 `{h}` 则替换为黄色片段；否则黄色片段拼在末尾
    private func combinedText(_ hl: String) -> Text {
        if text.contains("{h}") {
            let parts = text.components(separatedBy: "{h}")
            var out = Text(parts[0]).foregroundColor(.white)
            for i in 1..<parts.count {
                out = out + Text(" \(hl) ").foregroundColor(Self.highlightColor).bold() + Text(parts[i]).foregroundColor(.white)
            }
            return out
        }
        return Text(text).foregroundColor(.white)
            + Text(" \(hl)").foregroundColor(Self.highlightColor).bold()
    }
}

/// 游戏中奖公屏（136/138 全服中奖 · 对齐 H5 `game-win-public-msg.vue` L56-63）
private struct RowGameWinNotify: View {
    let payload: GameWinPayload
    let theme: PublicChatTheme
    let onTapNickname: (() -> Void)?

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, theme.scene == .party ? 8 : 6)
            .frame(maxWidth: theme.scene == .party ? 240 : 280, minHeight: theme.scene == .party ? 40 : nil, alignment: .leading)
            .background(background)
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 6) {
            AvatarView(urlString: payload.avatar, size: 24, kind: .user)
                .frame(width: 24, height: 24)
            HStack(spacing: 0) {
                nickname
                Text(" won ")
                    .foregroundColor(.white)
                Text(payload.winAmount)
                    .foregroundColor(theme.scene == .party ? Color(red: 1, green: 230/255, blue: 0) : Color(red: 254/255, green: 0, blue: 222/255))
                Text(" in [\(payload.gameName)]")
                    .foregroundColor(.white)
            }
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            if let icon = payload.gameIcon {
                CachedAsyncImage(url: URL(string: icon), contentMode: .fill) {
                    Color.white.opacity(0.15)
                }
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    @ViewBuilder
    private var nickname: some View {
        let label = Text(payload.nickname)
            .foregroundColor(Color(red: 26/255, green: 1.0, blue: 205/255))
        if let onTapNickname {
            Button(action: onTapNickname) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(payload.nickname))
        } else {
            label
        }
    }

    @ViewBuilder
    private var background: some View {
        if theme.scene == .party {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.30))
                CachedAsyncImage(
                    url: URL(string: "https://img.hnhily.link/mstatic/party/room-game-notice-bg.webp"),
                    contentMode: .fill,
                    persistent: true
                ) { Color.clear }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        } else {
            RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.30))
        }
    }
}

/// Party 场景通用昵称行（Party Regular / Gift 共用）
/// 对齐 H5 chat-list.vue L146-164：昵称 + Lv + VIP + role + platformAdmin
private struct PartyNicknameRow: View {
    let sender: SenderProfile?
    let onTapNickname: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            nickname
            if let lv = sender?.userLevel, lv > 0 {
                UserLevelBadge(level: lv, size: .small)
            }
            if sender?.isVip == true {
                VIPBadge(size: .small)
            }
            if let medals = sender?.medals {
                ForEach(Array(medals.enumerated()), id: \.offset) { _, medalURL in
                    CachedAsyncImage(url: URL(string: medalURL), contentMode: .fit) { Color.clear }
                        .frame(width: 16, height: 16)
                }
            }
            // 房管图标（对齐 H5 chat-list.vue L161 `h16 w16` · icon_lv_${role}.png）
            // v4:owner (role=1) → partyOwnerCrown / manager (role=2) → partyManagerBadge
            if let role = sender?.role {
                CDNAssetImage(role == .owner ? "partyOwnerCrown" : "partyManagerBadge")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(role == .owner ? "Owner" : "Manager")
            }
            // 平台管理员
            if sender?.isPlatformAdmin == true {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 1.0, green: 0.10, blue: 0.65))
                    .frame(width: 16, height: 16)
                    .accessibilityLabel("Platform Admin")
            }
        }
    }

    @ViewBuilder
    private var nickname: some View {
        let label = Text(sender?.nickname ?? "")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .lineLimit(1)
            .truncationMode(.tail)
        if let onTapNickname {
            Button(action: onTapNickname) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(sender?.nickname ?? ""))
        } else {
            label
        }
    }
}

/// Party 头像 + 头像框 动态尺寸 helper。
/// - **无 headFrame**：头像充满 32pt（对齐 H5 chat-list.vue L142 `v-image h-24 w-24` 但视觉上取 outer 32pt 布局对齐）
/// - **有 headFrame**：头像内 24pt + 框外扩 32pt（对齐 H5 `head-frame` absolute 覆盖布局）
private struct PartyAvatarWithFrame: View {
    let avatarURL: String?
    let headFrame: String?
    let userId: String?

    var body: some View {
        let hasHeadFrame = headFrame?.isEmpty == false
        // 有头像框：头像 24 + 框 32 外扩；无头像框：头像充满 32
        let avatarSize: CGFloat = hasHeadFrame ? 24 : 32
        let headwearRatio: CGFloat = hasHeadFrame ? 32.0 / 24.0 : 1.0
        AvatarView(
            urlString: avatarURL,
            size: avatarSize,
            kind: .user,
            headwearURL: hasHeadFrame ? headFrame : nil,
            headwearRatio: headwearRatio,
            userId: userId
        )
        .frame(width: 32, height: 32)
    }
}
