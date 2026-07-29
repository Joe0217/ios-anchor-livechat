import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L586-598
/// 视觉：w212 rounded-20 p8 · from-#5F8FBC-50% to-transparent 线性蓝渐变
/// 内容：
///   顶行：Lv 徽章 + VIP 徽章 + "Official Boost✨"（#FFE600 金）
///   底行：Welcome <fromNick> to the Platform Featured Newcomer's Room!
struct RowOfficialBoostEnter: View {
    let sender: SenderProfile?
    let theme: PublicChatTheme
    let onTapNickname: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let s = sender {
                    if let lv = s.userLevel, lv > 0 { UserLevelBadge(level: lv, size: .small) }
                    if s.isVip { VIPBadge(size: .small) }
                }
                Text("Official Boost✨")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(red: 1.0, green: 230/255, blue: 0))   // #FFE600
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Welcome ")
                    .font(theme.textFont)
                    .foregroundColor(.white)
                nickname
                Text(" to the Platform Featured Newcomer's Room!")
                    .font(theme.textFont)
                    .foregroundColor(.white)
            }
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(width: 212, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(red: 95/255, green: 143/255, blue: 188/255), Color.clear],
                startPoint: .leading, endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: 20)
        )
    }

    @ViewBuilder
    private var nickname: some View {
        let label = Text(sender?.nickname ?? "")
            .font(theme.textFont)
            .foregroundColor(.white)
        if let onTapNickname {
            Button(action: onTapNickname) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(sender?.nickname ?? ""))
        } else {
            label
        }
    }
}
