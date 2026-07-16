import SwiftUI

struct PublicChatSenderCapsule: View {
    let sender: SenderProfile
    let theme: PublicChatTheme

    var body: some View {
        HStack(spacing: 4) {
            if let lv = sender.userLevel, lv > 0 { UserLevelBadge(level: lv, size: .small) }
            if sender.isVip { VIPBadge(size: .small) }
            if sender.isHost { PublicChatHostBadge() }
            Text(sender.nickname + ":")
                .font(theme.nicknameFont)
                .foregroundColor(nicknameColor)
                .lineLimit(1)
            // v16.8：派对房身份徽章挂在昵称**后**（对齐 H5 message-user.vue:57 顺序：昵称 + role icon）
            // Live 场景 sender.role = nil → 内部 optional 分支不渲染，视觉零影响
            PublicChatRoleBadge(role: sender.role, size: 16)
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
