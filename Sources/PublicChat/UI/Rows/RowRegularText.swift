import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L367-448
/// 视觉：max-w249 min-h22 rounded-12 px-8 py4 · bg rgba(0,0,0,0.16) · 白字
/// 昵称 #1AFFCD 青绿 · text 白 12pt · 徽章 Lv + VIP(h12 w26) + newUser(h12 w25)
struct RowRegularText: View {
    let sender: SenderProfile?
    let content: String
    let mentions: [Mention]
    let translation: String?
    let replyToNick: String?
    let theme: PublicChatTheme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                inlineTextRun
                if let t = translation, !t.isEmpty {
                    Divider().overlay(Color.white.opacity(0.16))
                    Text(t)
                        .font(theme.textFont)
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(maxWidth: 249, alignment: .leading)
        .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
    }

    private var inlineTextRun: some View {
        // 昵称 + 徽章 + 正文一行流（不能用 HStack + Text 分开，否则换行不自然）
        // 使用 Text concatenation
        buildText()
            .font(theme.textFont)
            .foregroundColor(.white)
    }

    @ViewBuilder private func buildText() -> some View {
        HStack(spacing: 4) {
            if let s = sender {
                if let lv = s.userLevel, lv > 0 { PublicChatLevelBadge(level: lv) }
                if s.isVip { PublicChatVipBadge() }
                Text("\(s.nickname):")
                    .font(theme.nicknameFont)
                    .foregroundColor(Color(red: 26/255, green: 1.0, blue: 205/255))  // #1AFFCD
                    .lineLimit(1)
            }
            Text(content)
                .font(theme.textFont)
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
