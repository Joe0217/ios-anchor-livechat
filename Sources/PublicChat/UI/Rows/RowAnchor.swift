import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L348-364
/// 视觉：`.anchor-box` bg rgba(152,23,202,0.16) + border rgba(164,49,208,0.5)
/// max-w249 min-h22 rounded-12 px8 py-5 · live_host_icon(h12 w31) + 粉昵称 #FE00DE + text 白
struct RowAnchor: View {
    let sender: SenderProfile?
    let content: String
    let translation: String?
    let theme: PublicChatTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 4) {
                // live_host_icon 占位（未来接切图 https://img.hnhily.link/mstatic/live/live_host_icon.webp）
                Text("HOST")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .frame(height: 12)
                    .background(Color(red: 254/255, green: 0, blue: 222/255).opacity(0.9), in: Capsule())
                nameAndBodyText
            }
            if let t = translation, !t.isEmpty {
                Text(t)
                    .font(theme.textFont)
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 249, alignment: .leading)
        .background(anchorBoxBackground)
    }

    @ViewBuilder private var nameAndBodyText: some View {
        HStack(spacing: 2) {
            Text("\(sender?.nickname ?? ""):")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(red: 254/255, green: 0, blue: 222/255))  // #FE00DE
            Text(content)
                .font(theme.textFont)
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var anchorBoxBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(red: 152/255, green: 23/255, blue: 202/255).opacity(0.16))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(red: 164/255, green: 49/255, blue: 208/255).opacity(0.5), lineWidth: 1)
            )
    }
}
