import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L367-448
/// 视觉：max-w249 min-h22 rounded-12 px-8 py4 · bg rgba(0,0,0,0.16) · 白字
/// 昵称 #1AFFCD 青绿 · text 白 12pt · 徽章 Lv + VIP(h12 w26) + newUser(h12 w25)
///
/// v22（2026-07-10）：改造为 HStack(badges) + inline Text concat 支持长文本自动换行
/// v23（2026-07-12）：加翻译（对齐 H5 msgItem CTranslate；只对方消息 tap 图标触发；已翻译显示分隔线 + 译文）
/// v24（2026-07-13）：翻译按钮改为 inline 跟在文字末尾(用户反馈)——SF Symbol Image concat 到 Text；tap 气泡触发翻译
struct RowRegularText: View {
    let sender: SenderProfile?
    let content: String
    let mentions: [Mention]
    let translation: String?
    let replyToNick: String?
    let theme: PublicChatTheme
    /// tap 翻译回调；nil 时不显示图标（sender 是自己 / 已翻译 / 场景不支持）
    let onTapTranslate: (() -> Void)?
    /// v25（2026-07-13）：翻译进行中(caller 从 pendingTranslateIds 派生)。
    /// true 时图标替换为沙漏,tap 禁二次触发,给用户"已在翻译中"视觉反馈
    let isTranslating: Bool
    /// v24（B4 · 对齐 H5 §9.12.4 hi 气泡）：tap hi 图标回调；nil 时不显示图标
    /// （PublicChatRow 门控：仅 `.text` variant + `sender?.isSelf == false` + `theme.scene == .live` 时传入非 nil）
    let onTapHi: (() -> Void)?
    /// 发送者昵称点击名片卡；自己或缺少 userId 时由上层传 nil。
    let onTapNickname: (() -> Void)?

    init(sender: SenderProfile?,
         content: String,
         mentions: [Mention],
         translation: String?,
         replyToNick: String?,
         theme: PublicChatTheme,
         onTapTranslate: (() -> Void)? = nil,
         isTranslating: Bool = false,
         onTapHi: (() -> Void)? = nil,
         onTapNickname: (() -> Void)? = nil) {
        self.sender = sender
        self.content = content
        self.mentions = mentions
        self.translation = translation
        self.replyToNick = replyToNick
        self.theme = theme
        self.onTapTranslate = onTapTranslate
        self.isTranslating = isTranslating
        self.onTapHi = onTapHi
        self.onTapNickname = onTapNickname
    }

    var body: some View {
        let showTranslateInline = translation == nil && onTapTranslate != nil
        let hasChatSkin = sender?.chatBubble?.isEmpty == false
        let bubble = VStack(alignment: .leading, spacing: 3) {
            if hasChatSkin {
                // 皮肤边框的内容宽度比默认气泡窄。身份/昵称独占第一行，正文放第二行，
                // 避免等级标签与长正文相互挤压。
                HStack(alignment: .center, spacing: 4) {
                    badgesCluster
                    nicknameAndReply
                        .fixedSize(horizontal: false, vertical: true)
                }
                messageText(showTranslate: showTranslateInline)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .center, spacing: 4) {
                    badgesCluster
                    inlineText(showTranslate: showTranslateInline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let t = translation, !t.isEmpty {
                Divider().overlay(Color.white.opacity(0.16))
                Text(t)
                    .font(theme.textFont)
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // H5 `.chat-bubble-custom` 有 `padding: 0 !important`，仅保留它的 24/14
        // border 内容区，不能叠加直播行默认的 `px8 py4`。
        .padding(.horizontal, hasChatSkin ? ChatSkinMetrics.horizontalContentInset : 8)
        .padding(.vertical, hasChatSkin ? ChatSkinMetrics.verticalContentInset : 4)
        .frame(minHeight: 22)
        .frame(maxWidth: 249, alignment: .leading)
        .background(bubbleBackground)
        .padding(.vertical, hasChatSkin ? ChatSkinMetrics.livePublicMessageVerticalSpacing : 0)
        .contentShape(Rectangle())
        .accessibilityLabel(showTranslateInline
            ? Text("\(sender?.nickname ?? ""): \(content) \(L10n.publicScreenTranslate)")
            : Text("\(sender?.nickname ?? ""): \(content)"))

        // v24（B4）：气泡 + 可选 hi 图标兄弟（H5 messageScroller.vue L435-472 用户消息末尾 hi 图标）
        if let tapHi = onTapHi {
            HStack(alignment: .center, spacing: 4) {
                PublicChatContentHuggingLayout(maxWidth: 249) { bubble }
                Button(action: tapHi) {
                    // v24 verify finding · HIG 44x44 hit target：外层扩到 44 保 tap 命中率，
                    // 视觉圆 20×20 保原设计尺寸；内 background Circle 附着在 20 icon 上
                    Image(systemName: "hand.wave.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(red: 254/255, green: 0, blue: 222/255))   // #FE00DE 主播粉
                        .frame(width: 20, height: 20)
                        .background(Color.black.opacity(0.16), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // v24 verify finding · a11y label 带 nickname 上下文，多消息间可区分
                .accessibilityLabel(Text("\(L10n.publicScreenHiActionA11y): \(sender?.nickname ?? "")"))
            }
        } else {
            PublicChatContentHuggingLayout(maxWidth: 249) { bubble }
        }
    }

    @ViewBuilder private var badgesCluster: some View {
        if let s = sender {
            HStack(spacing: 4) {
                if s.guardianLevel > 0, theme.scene == .live {
                    CDNAssetImage(GuardianArtwork.tabIcon(for: GuardianLevel.decoded(s.guardianLevel)))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .accessibilityLabel(Text(L10n.guardianTitle))
                }
                // v24（B1 · H5 §9.6 messageScroller.vue L373）：大 R 徽章前置于 Level/VIP；
                // 仅 Live 场景 rendering（H5 铁律"仅主态"—— sender.isActiveTycoon 由 LivePublicChatAdapter 门控透传）
                if s.isActiveTycoon && theme.scene == .live { ActiveTycoonBadge(style: .bigRText, size: .small) }
                if let lv = s.userLevel, lv > 0 { UserLevelBadge(level: lv, size: .small) }
                if s.isVip {
                    VIPBadge(size: .small)
                } else if s.isNewUser {
                    LiveNewUserBadge()
                }
            }
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if let raw = sender?.chatBubble, let url = URL(string: raw), !raw.isEmpty {
            NinePatchImageView(url: url)
        } else if theme.scene == .live, let guardianLevel = sender?.guardianLevel, guardianLevel > 0 {
            GuardianChatBubbleBackground(level: guardianLevel)
        } else {
            RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.16))
        }
    }

    /// 默认气泡中的昵称 + 正文 + (可选)inline 翻译图标。
    /// 翻译图标随文字末尾 wrap 到最后一行末（对齐 iOS 用户"跟在文字后面"预期）
    ///
    /// v24（B4 M6+M7 finding · 对齐 H5 messageScroller.vue L352-354）：
    /// - **无 replyToNick**：`{nick}: ` 单尾冒号 + 尾空格
    ///   - 主播（`sender.isHost`）nick 用 **主播粉 #FE00DE**（H5 主播分支）
    ///   - 普通用户 nick 用 **青绿 #1AFFCD**
    /// - **有 replyToNick**：主播 `@` 用户格式 `{anchorNick} @ {replyNick}: {text}`
    ///   - anchorNick 主播粉，`@` 白 + 空格，replyNick 青绿 + 尾冒号空格，text 白
    ///   - **iOS anchor 自发消息** 恒进此分支（只有主播能发带 replyNick 的公屏），因此 anchorNick 上主播粉
    private func inlineText(showTranslate: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            nicknameAndReply
            messageText(showTranslate: showTranslate)
        }
    }

    /// 皮肤气泡首行：昵称及 @ 回复目标。正文不在此行，避免长文压缩等级标签。
    private var nicknameAndReply: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            nicknameLabel
            replyPrefix
        }
    }

    @ViewBuilder
    private var nicknameLabel: some View {
        if let onTapNickname {
            Button(action: onTapNickname) {
                nicknameText
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(sender?.nickname ?? ""))
        } else {
            nicknameText
        }
    }

    private var nicknameText: Text {
        let anchorPink = Color(red: 254/255, green: 0, blue: 222/255)   // #FE00DE
        let userTeal   = Color(red: 26/255, green: 1.0, blue: 205/255)  // #1AFFCD
        let nickColor: Color = (sender?.isHost == true) ? anchorPink : userTeal
        let hasReply = (replyToNick?.isEmpty == false)
        // 有 reply 时 nick 后无冒号；无 reply 保留冒号
        let nickSuffix = hasReply ? " " : ": "
        return Text("\(sender?.nickname ?? "")\(nickSuffix)")
            .font(theme.nicknameFont)
            .foregroundColor(nickColor)
    }

    private var replyPrefix: Text {
        let userTeal = Color(red: 26/255, green: 1.0, blue: 205/255)
        guard let nick = replyToNick, !nick.isEmpty else { return Text("") }
        // 「@ 青绿 replyNick: 」白 @ + 空格 + 青绿 nick + 白冒号 + 空格
        return Text("@ ")
            .font(theme.textFont).foregroundColor(.white)
            + Text(nick)
            .font(theme.textFont).foregroundColor(userTeal)
            + Text(": ")
            .font(theme.textFont).foregroundColor(.white)
    }

    private func messageText(showTranslate: Bool) -> some View {
        let bodyText = Text(content)
            .font(theme.textFont)
            .foregroundColor(.white)
        let messageText: Text = {
            var result = bodyText
            if showTranslate {
                // SF Symbol Image 作为 Text attachment concat；空格分隔避免紧贴末字
                // v25:loading 时用 hourglass(iOS 16 静态兼容);tap 期间视觉反馈
                let iconName = isTranslating ? "hourglass" : "character.book.closed.fill"
                let iconColor: Color = isTranslating
                    ? Color.white.opacity(0.5)
                    : Color(red: 196/255, green: 155/255, blue: 1.0) // #C49BFF
                let iconText = Text(" ") + Text(Image(systemName: iconName))
                    .font(theme.textFont)
                    .foregroundColor(iconColor)
                result = result + iconText
            }
            return result
        }()
        let tappableMessageText = messageText
            .contentShape(Rectangle())
            .onTapGesture {
                if showTranslate && !isTranslating { onTapTranslate?() }
            }
            .accessibilityAddTraits(showTranslate ? .isButton : [])

        return tappableMessageText
    }
}

/// H5 `messageScroller.vue` 的守护气泡降级样式。
/// 自定义 chatBubble URL 始终优先；缺失时才按铜/银/金等级绘制此本地背景。
private struct GuardianChatBubbleBackground: View {
    let level: Int
    @State private var goldGlow = false

    var body: some View {
        switch level {
        case 3...:
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 1, green: 195 / 255, blue: 58 / 255).opacity(0.30),
                                 Color(red: 1, green: 235 / 255, blue: 150 / 255).opacity(0.12)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 1, green: 210 / 255, blue: 80 / 255).opacity(0.85), lineWidth: 1))
                .shadow(color: Color(red: 1, green: 200 / 255, blue: 60 / 255).opacity(goldGlow ? 0.58 : 0.25), radius: goldGlow ? 7 : 3)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                        goldGlow = true
                    }
                }
        case 2:
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 192 / 255, green: 204 / 255, blue: 218 / 255).opacity(0.28),
                                 Color(red: 192 / 255, green: 204 / 255, blue: 218 / 255).opacity(0.10)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 220 / 255, green: 230 / 255, blue: 245 / 255).opacity(0.70), lineWidth: 1))
        default:
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 1, green: 106 / 255, blue: 61 / 255).opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 1, green: 106 / 255, blue: 61 / 255).opacity(0.45), lineWidth: 1))
        }
    }
}
