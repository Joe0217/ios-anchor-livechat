import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L652-659
/// 视觉：max-w249 rounded-12 px8 py4 · bg-#0000ff/36 蓝紫 · border-#A7B0EB
/// 内容：📢 + "Announcement Management" 顶部一行加粗；正文 whitespace-pre-wrap 换行
struct RowAnnouncement: View {
    let text: String
    let kind: AnnouncementKind
    let theme: PublicChatTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(headerText)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Color(red: 26/255, green: 1.0, blue: 205/255))   // 复用青绿高亮
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 249, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0, green: 0, blue: 1.0).opacity(0.36))   // #0000ff/36
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(red: 167/255, green: 176/255, blue: 235/255), lineWidth: 1)
                )
        )
    }

    private var headerText: String {
        switch kind {
        case .liveOfficial: return "📢 Announcement"
        case .partyRoom:    return "📢 Room Announcement"
        }
    }
}
