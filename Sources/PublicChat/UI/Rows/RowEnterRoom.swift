import SwiftUI

/// Standard live-room entry row. Official Boost uses RowOfficialBoostEnter instead.
struct RowEnterRoom: View {
    let sender: SenderProfile?
    let vehicleImg: String?
    let itemSmallImg: String?
    let theme: PublicChatTheme
    let onTapNickname: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            if let sender {
                if let level = sender.userLevel, level > 0 {
                    UserLevelBadge(level: level, size: .small)
                }
                nickname(sender)
            }
            Text(L10n.publicScreenEnteredRoom)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func nickname(_ sender: SenderProfile) -> some View {
        let label = Text(sender.nickname)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Color(red: 26/255, green: 1.0, blue: 205/255))
            .lineLimit(1)
            .frame(maxWidth: 50, alignment: .leading)
        if let onTapNickname {
            Button(action: onTapNickname) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(sender.nickname))
        } else {
            label
        }
    }
}
