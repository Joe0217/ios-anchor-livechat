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

    init(sender: SenderProfile?,
         content: String,
         mentions: [Mention],
         translation: String?,
         replyToNick: String?,
         theme: PublicChatTheme,
         onTapTranslate: (() -> Void)? = nil) {
        self.sender = sender
        self.content = content
        self.mentions = mentions
        self.translation = translation
        self.replyToNick = replyToNick
        self.theme = theme
        self.onTapTranslate = onTapTranslate
    }

    var body: some View {
        let showTranslateInline = translation == nil && onTapTranslate != nil
        VStack(alignment: .leading, spacing: 3) {
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
            if showTranslateInline { onTapTranslate?() }
        }
        .accessibilityAddTraits(showTranslateInline ? .isButton : [])
        .accessibilityLabel(showTranslateInline
            ? Text("\(sender?.nickname ?? ""): \(content) \(L10n.publicScreenTranslate)")
            : Text("\(sender?.nickname ?? ""): \(content)"))
    }

    @ViewBuilder private var badgesCluster: some View {
        if let s = sender {
            HStack(spacing: 4) {
                if let lv = s.userLevel, lv > 0 { UserLevelBadge(level: lv, size: .small) }
                if s.isVip { PublicChatVipBadge() }
            }
        }
    }

    /// 昵称 + 正文 + (可选)inline 翻译图标 —— 全用 Text concat；SwiftUI 自动 wrap 到多行
    /// 翻译图标随文字末尾 wrap 到最后一行末（对齐 iOS 用户"跟在文字后面"预期）
    private func inlineText(showTranslate: Bool) -> Text {
        let nickText = Text("\(sender?.nickname ?? ""): ")
            .font(theme.nicknameFont)
            .foregroundColor(Color(red: 26/255, green: 1.0, blue: 205/255))   // #1AFFCD
        let bodyText = Text(content)
            .font(theme.textFont)
            .foregroundColor(.white)
        var result = nickText + bodyText
        if showTranslate {
            // SF Symbol Image 作为 Text attachment concat；空格分隔避免紧贴末字
            let iconText = Text(" ") + Text(Image(systemName: "character.book.closed.fill"))
                .font(theme.textFont)
                .foregroundColor(Color(red: 196/255, green: 155/255, blue: 1.0)) // #C49BFF
            result = result + iconText
        }
        return result
    }
}
