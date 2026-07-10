import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L367-448
/// 视觉：max-w249 min-h22 rounded-12 px-8 py4 · bg rgba(0,0,0,0.16) · 白字
/// 昵称 #1AFFCD 青绿 · text 白 12pt · 徽章 Lv + VIP(h12 w26) + newUser(h12 w25)
///
/// v22（2026-07-10）：改造为 HStack(badges) + inline Text concat 支持长文本自动换行
struct RowRegularText: View {
    let sender: SenderProfile?
    let content: String
    let mentions: [Mention]
    let translation: String?
    let replyToNick: String?
    let theme: PublicChatTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 4) {
                badgesCluster
                inlineText
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
    }

    @ViewBuilder private var badgesCluster: some View {
        if let s = sender {
            HStack(spacing: 4) {
                if let lv = s.userLevel, lv > 0 { UserLevelBadge(level: lv, size: .small) }
                if s.isVip { PublicChatVipBadge() }
            }
        }
    }

    /// 昵称 + 正文用 Text concat；SwiftUI 自动 wrap 到多行
    private var inlineText: Text {
        let nickText = Text("\(sender?.nickname ?? ""): ")
            .font(theme.nicknameFont)
            .foregroundColor(Color(red: 26/255, green: 1.0, blue: 205/255))   // #1AFFCD
        let bodyText = Text(content)
            .font(theme.textFont)
            .foregroundColor(.white)
        return nickText + bodyText
    }
}
