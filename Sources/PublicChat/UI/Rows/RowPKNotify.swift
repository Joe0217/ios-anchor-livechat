import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L519-522
/// 视觉：max-w249 min-h22 rounded-12 px-8 py-5 · bg-#D33901/30 暗红 · border-#FA7800/50
/// 内容：RichSegment 数组 v-html 拼接
struct RowPKNotify: View {
    let richText: [RichSegment]
    let theme: PublicChatTheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(richText.enumerated()), id: \.offset) { _, seg in
                segView(seg)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 249, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 211/255, green: 57/255, blue: 1/255).opacity(0.3))   // #D33901/30
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(red: 250/255, green: 120/255, blue: 0).opacity(0.5), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder private func segView(_ seg: RichSegment) -> some View {
        switch seg {
        case .text(let s, let color):
            Text(s)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(color)
        case .highlight(let s, let color):
            Text(s)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
        case .iconURL(let url, let size):
            if let u = URL(string: url) {
                CachedAsyncImage(url: u, contentMode: .fit) { Color.clear }
                    .frame(width: size.width, height: size.height)
            }
        }
    }
}
