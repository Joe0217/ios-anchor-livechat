import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L549-561
/// 视觉：`.rps-win-msg` max-w-268 rounded-14 px-8 py-6 lh-20
/// bg 紫渐变 rgba(160,101,216,0.6) → rgba(160,101,216,0) · border rgba(174,221,255,0.6)
/// 内容：ye.webp(h28 w28) + 顶行 nickname #FFE000 "wins RPS" · 底行 " get " + medal img + "*Nh"
struct RowRpsWin: View {
    let sender: SenderProfile?
    let medalUrl: String?
    let medalHours: Int?
    let theme: PublicChatTheme

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 20))
                .foregroundColor(.yellow)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(sender?.nickname ?? "")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Color(red: 1.0, green: 224/255, blue: 0))   // #FFE000
                        .lineLimit(1)
                    Text("wins RPS")
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                }
                HStack(spacing: 4) {
                    Text("get")
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                    if let m = medalUrl, let u = URL(string: m), !m.isEmpty {
                        CachedAsyncImage(url: u, contentMode: .fit) { Color.clear }
                            .frame(width: 50, height: 14)
                    }
                    if let h = medalHours {
                        Text("*\(h)h")
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 268, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 160/255, green: 101/255, blue: 216/255).opacity(0.6),
                            Color(red: 160/255, green: 101/255, blue: 216/255).opacity(0)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color(red: 174/255, green: 221/255, blue: 1.0).opacity(0.6), lineWidth: 1)
                )
        )
    }
}
