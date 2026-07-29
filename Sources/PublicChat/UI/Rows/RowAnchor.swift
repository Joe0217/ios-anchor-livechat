import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L348-364
/// 视觉：`.anchor-box` bg rgba(152,23,202,0.16) + border rgba(164,49,208,0.5)
/// max-w249 min-h22 rounded-12 px8 py-5 · live_host_icon(h12 w31) + 粉昵称 #FE00DE + text 白
///
/// v22（2026-07-10）：正文改 Text concat 支持自动换行
struct RowAnchor: View {
    let sender: SenderProfile?
    let content: String
    let translation: String?
    let theme: PublicChatTheme
    let onTapNickname: (() -> Void)?

    var body: some View {
        let hasChatSkin = sender?.chatBubble?.isEmpty == false
        VStack(alignment: .leading, spacing: 3) {
            if hasChatSkin {
                HStack(alignment: .center, spacing: 4) {
                    hostIcon
                    nicknameText
                }
                // 自定义皮肤时正文单列，避免长消息把主播标识与昵称压缩到窄列。
                Text(content)
                    .font(theme.textFont)
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 35)
            } else {
                HStack(alignment: .center, spacing: 4) {
                    hostIcon
                    inlineText
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let t = translation, !t.isEmpty {
                Text(t)
                    .font(theme.textFont)
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    // H5 译文容器是 `ml4`。
                    .padding(.leading, 4)
            }
        }
        // H5 `.chat-bubble-custom` 的 `padding: 0 !important` 会覆盖主播行的 `px8 py5`。
        .padding(.horizontal, hasChatSkin ? ChatSkinMetrics.horizontalContentInset : 8)
        .padding(.vertical, hasChatSkin ? ChatSkinMetrics.verticalContentInset : 5)
        .frame(minHeight: 22)
        .frame(maxWidth: 249, alignment: .leading)
        .background(anchorBoxBackground)
        .padding(.vertical, hasChatSkin ? ChatSkinMetrics.livePublicMessageVerticalSpacing : 0)
    }

    private var inlineText: some View {
        let bodyText = Text(content)
            .font(theme.textFont)
            .foregroundColor(.white)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            nicknameText
            bodyText
        }
    }

    private var hostIcon: some View {
        CachedAsyncImage(
            url: URL(string: "https://img.hnhily.link/mstatic/live/live_host_icon.webp"),
            contentMode: .fill,
            persistent: true
        ) {
            Text("HOST")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 31, height: 12)
                .background(Color(red: 254/255, green: 0, blue: 222/255).opacity(0.9), in: Capsule())
        }
        .frame(width: 31, height: 12)
    }

    @ViewBuilder
    private var nicknameText: some View {
        let label = Text("\(sender?.nickname ?? ""): ")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Color(red: 254/255, green: 0, blue: 222/255))
        if let onTapNickname {
            Button(action: onTapNickname) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(sender?.nickname ?? ""))
        } else {
            label
        }
    }

    @ViewBuilder
    private var anchorBoxBackground: some View {
        let fallback = RoundedRectangle(cornerRadius: 12)
            .fill(Color(red: 152/255, green: 23/255, blue: 202/255).opacity(0.16))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(red: 164/255, green: 49/255, blue: 208/255).opacity(0.5), lineWidth: 1)
            )
        if let raw = sender?.chatBubble, let url = URL(string: raw), !raw.isEmpty {
            NinePatchImageView(url: url)
        } else {
            fallback
        }
    }
}
