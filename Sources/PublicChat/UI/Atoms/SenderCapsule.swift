import SwiftUI

struct PublicChatSenderCapsule: View {
    let sender: SenderProfile
    let theme: PublicChatTheme

    var body: some View {
        HStack(spacing: 4) {
            if let lv = sender.userLevel, lv > 0 { PublicChatLevelBadge(level: lv) }
            if sender.isVip { PublicChatVipBadge() }
            if sender.isHost { PublicChatHostBadge() }
            Text(sender.nickname + ":")
                .font(theme.nicknameFont)
                .foregroundColor(nicknameColor)
                .lineLimit(1)
        }
    }

    private var nicknameColor: Color {
        switch sender.nicknameColor {
        case .anchor:  return Color(red: 254/255, green: 0, blue: 222/255)   // #FE00DE
        case .her:     return Color(red: 238/255, green: 122/255, blue: 80/255)  // #EE7A50
        case .special: return Color(red: 1.0, green: 20/255, blue: 200/255)
        case .host:    return .orange
        case .default: return theme.defaultNicknameColor
        }
    }
}
