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

    init(sender: SenderProfile?,
         content: String,
         mentions: [Mention],
         translation: String?,
         replyToNick: String?,
         theme: PublicChatTheme,
         onTapTranslate: (() -> Void)? = nil,
         isTranslating: Bool = false,
         onTapHi: (() -> Void)? = nil) {
        self.sender = sender
        self.content = content
        self.mentions = mentions
        self.translation = translation
        self.replyToNick = replyToNick
        self.theme = theme
        self.onTapTranslate = onTapTranslate
        self.isTranslating = isTranslating
        self.onTapHi = onTapHi
    }

    var body: some View {
        let showTranslateInline = translation == nil && onTapTranslate != nil
        let bubble = VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 4) {
                badgesCluster
                inlineText(showTranslate: showTranslateInline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let t = translation, !t.isEmpty {
                Divider().overlay(Color.white.opacity(0.16))
                Text(t)
                    .font(theme.textFont)
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 249, alignment: .leading)
        .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture {
            if showTranslateInline && !isTranslating { onTapTranslate?() }
        }
        .accessibilityAddTraits(showTranslateInline ? .isButton : [])
        .accessibilityLabel(showTranslateInline
            ? Text("\(sender?.nickname ?? ""): \(content) \(L10n.publicScreenTranslate)")
            : Text("\(sender?.nickname ?? ""): \(content)"))

        // v24（B4）：气泡 + 可选 hi 图标兄弟（H5 messageScroller.vue L435-472 用户消息末尾 hi 图标）
        if let tapHi = onTapHi {
            HStack(alignment: .center, spacing: 4) {
                bubble
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
            bubble
        }
    }

    @ViewBuilder private var badgesCluster: some View {
        if let s = sender {
            HStack(spacing: 4) {
                // v24（B1 · H5 §9.6 messageScroller.vue L373）：大 R 徽章前置于 Level/VIP；
                // 仅 Live 场景 rendering（H5 铁律"仅主态"—— sender.isActiveTycoon 由 LivePublicChatAdapter 门控透传）
                if s.isActiveTycoon && theme.scene == .live { ActiveTycoonBadge(style: .bigRText, size: .small) }
                if let lv = s.userLevel, lv > 0 { UserLevelBadge(level: lv, size: .small) }
                if s.isVip { VIPBadge(size: .small) }
            }
        }
    }

    /// 昵称 + 正文 + (可选)inline 翻译图标 —— 全用 Text concat；SwiftUI 自动 wrap 到多行
    /// 翻译图标随文字末尾 wrap 到最后一行末（对齐 iOS 用户"跟在文字后面"预期）
    ///
    /// v24（B4 M6+M7 finding · 对齐 H5 messageScroller.vue L352-354）：
    /// - **无 replyToNick**：`{nick}: ` 单尾冒号 + 尾空格
    ///   - 主播（`sender.isHost`）nick 用 **主播粉 #FE00DE**（H5 主播分支）
    ///   - 普通用户 nick 用 **青绿 #1AFFCD**
    /// - **有 replyToNick**：主播 `@` 用户格式 `{anchorNick} @ {replyNick}: {text}`
    ///   - anchorNick 主播粉，`@` 白 + 空格，replyNick 青绿 + 尾冒号空格，text 白
    ///   - **iOS anchor 自发消息** 恒进此分支（只有主播能发带 replyNick 的公屏），因此 anchorNick 上主播粉
    private func inlineText(showTranslate: Bool) -> Text {
        let anchorPink = Color(red: 254/255, green: 0, blue: 222/255)   // #FE00DE
        let userTeal   = Color(red: 26/255, green: 1.0, blue: 205/255)  // #1AFFCD
        let nickColor: Color = (sender?.isHost == true) ? anchorPink : userTeal
        let hasReply = (replyToNick?.isEmpty == false)
        // 有 reply 时 nick 后无冒号；无 reply 保留冒号
        let nickSuffix = hasReply ? " " : ": "
        let nickText = Text("\(sender?.nickname ?? "")\(nickSuffix)")
            .font(theme.nicknameFont)
            .foregroundColor(nickColor)
        let replyPrefix: Text = {
            guard let nick = replyToNick, !nick.isEmpty else { return Text("") }
            // 「@ 青绿 replyNick: 」白 @ + 空格 + 青绿 nick + 白冒号 + 空格
            return Text("@ ")
                .font(theme.textFont).foregroundColor(.white)
                + Text(nick)
                .font(theme.textFont).foregroundColor(userTeal)
                + Text(": ")
                .font(theme.textFont).foregroundColor(.white)
        }()
        let bodyText = Text(content)
            .font(theme.textFont)
            .foregroundColor(.white)
        var result = nickText + replyPrefix + bodyText
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
    }
}
