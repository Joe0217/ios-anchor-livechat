import SwiftUI

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

    var body: some View {
        Group {
            switch message.variant.discriminator {
            case .text, .anchor, .gift, .luckyGift, .partyLuckyNumber, .system:
                textGiftGroup
            case .enterRoom, .officialBoostEnter, .announcement, .pkNotify, .partyModeSwitch, .partyBattle:
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
                    isTranslating: isTranslating
                )
            } else {
                RowRegularText(
                    sender: message.sender, content: c, mentions: mentions,
                    translation: translation, replyToNick: replyToNick, theme: theme,
                    onTapTranslate: showTranslate ? { onTapTranslate?(message) } : nil,
                    isTranslating: isTranslating,
                    onTapHi: showHi ? { onTapHi?(message) } : nil
                )
            }
        case .anchor(let c, let translation):
            RowAnchor(sender: message.sender, content: c, translation: translation, theme: theme)
        case .gift(let url, let name, let count):
            if theme.scene == .party {
                RowPartyGift(sender: message.sender, iconURL: url, name: name, count: count)
            } else {
                RowGift(sender: message.sender, iconURL: url, name: name, count: count, theme: theme)
            }
        case .luckyGift(let url, let count, let total):
            RowLuckyGift(sender: message.sender, iconURL: url, count: count, totalReward: total, theme: theme)
        case .partyLuckyNumber(let number, let didWin):
            RowPartyLuckyNumber(sender: message.sender, number: number, didWin: didWin)
        case .system(let text):
            RowAnnouncement(text: text, kind: theme.scene == .party ? .partyRoom : .liveOfficial, theme: theme)
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
        case .rpsWin(let url, let hours):
            RowRpsWin(sender: message.sender, medalUrl: url, medalHours: hours, theme: theme)
        case .wheelRes(let text, let hl):
            RowWheelRes(sender: message.sender, resultText: text, resultHighlight: hl, theme: theme)
        case .winnerBroadcast(let name, let qty, let img, let cta, let avatar):
            RowWinnerBroadcast(activityName: name, quantity: qty, imageURL: img,
                               joinCTA: cta, avatar: avatar, theme: theme)
        case .wishlistEffect:
            RowWishlistEffect(sender: message.sender)
        case .diamondGift(let sub):
            RowDiamondGift(subType: sub, theme: theme)
        case .gameWinNotify(let payload):
            // v3：全服/本房游戏中奖公屏（对齐 H5 game-win-public-msg.vue）
            RowGameWinNotify(payload: payload)
        default:
            EmptyView()
        }
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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // v4 动态尺寸：无头像框时头像充满 32pt（否则头像内 24pt 视觉过小）；有头像框时头像 24pt 框外扩 32pt
            PartyAvatarWithFrame(
                avatarURL: sender?.avatarURL,
                headFrame: sender?.headFrame,
                userId: sender?.userId
            )
            VStack(alignment: .leading, spacing: 6) {
                PartyNicknameRow(sender: sender)
                bubbleBody
                if let t = translation, !t.isEmpty {
                    Text(t)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: 213, alignment: .leading)
                        .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var bubbleBody: some View {
        let showTranslate = translation == nil && onTapTranslate != nil
        return HStack(alignment: .top, spacing: 4) {
            bodyText(showTranslate: showTranslate)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 213, alignment: .leading)
        .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 12))
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
}

/// Party 送礼消息（对齐 H5 chat-list.vue L183-204：头像 + 昵称行 + Sends to 气泡）
private struct RowPartyGift: View {
    let sender: SenderProfile?
    let iconURL: String?
    let name: String
    let count: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PartyAvatarWithFrame(
                avatarURL: sender?.avatarURL,
                headFrame: sender?.headFrame,
                userId: sender?.userId
            )
            VStack(alignment: .leading, spacing: 6) {
                PartyNicknameRow(sender: sender)
                giftBubble
            }
        }
    }

    private var giftBubble: some View {
        HStack(alignment: .center, spacing: 6) {
            Text("Sends to")
                .font(.system(size: 13))
                .foregroundColor(.white)
            // MVP：单接收人昵称/多接收人 UI 简化为通用 "Room" — H5 完整版含 receivers/receiversIcons 分支，
            // PartyGiftEvent.receiverUserIds 现只有 userId 数组无昵称，未来接入 receiverNicknames 时扩
            Text("Room")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(red: 26/255, green: 1.0, blue: 205/255))  // #1AFFCD
            CachedAsyncImage(url: URL(string: iconURL ?? ""), contentMode: .fill) {
                Image(systemName: "gift.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.08))
            }
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text("x\(count)")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 240, alignment: .leading)
        .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 8))
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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PartyAvatarWithFrame(
                avatarURL: sender?.avatarURL,
                headFrame: sender?.headFrame,
                userId: sender?.userId
            )
            VStack(alignment: .leading, spacing: 6) {
                PartyNicknameRow(sender: sender)
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
            Image("partyPkLogo")
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

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            AvatarView(urlString: payload.avatar, size: 24, kind: .user)
                .frame(width: 24, height: 24)
            (Text(payload.nickname)
                .foregroundColor(Color(red: 26/255, green: 1.0, blue: 205/255))   // #1AFFCD
             + Text(" won ").foregroundColor(.white)
             + Text(payload.winAmount).foregroundColor(Color(red: 254/255, green: 0, blue: 222/255))  // #FE00DE
             + Text(" in [\(payload.gameName)]").foregroundColor(.white))
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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 280, alignment: .leading)
        .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Party 场景通用昵称行（Party Regular / Gift 共用）
/// 对齐 H5 chat-list.vue L146-164：昵称 + Lv + VIP + role + platformAdmin
private struct PartyNicknameRow: View {
    let sender: SenderProfile?

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Text(sender?.nickname ?? "")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 106, alignment: .leading)
            if let lv = sender?.userLevel, lv > 0 {
                UserLevelBadge(level: lv, size: .small)
            }
            if sender?.isVip == true {
                VIPBadge(size: .small)
            }
            // 房管图标（对齐 H5 chat-list.vue L161 `h16 w16` · icon_lv_${role}.png）
            // v4:owner (role=1) → partyOwnerCrown / manager (role=2) → partyManagerBadge
            if let role = sender?.role {
                Image(role == .owner ? "partyOwnerCrown" : "partyManagerBadge")
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
