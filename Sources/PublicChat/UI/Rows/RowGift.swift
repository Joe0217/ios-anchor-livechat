import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L486-517
/// 视觉：max-w249 min-h24 rounded-12 px8 py5 · bg rgba(0,0,0,0.16)
/// 格式：Lv + VIP/NEW + 昵称 #1AFFCD + " Send " 白 + gift icon 16pt + " x N" 白
struct RowGift: View {
    let sender: SenderProfile?
    let iconURL: String?
    let name: String
    let count: Int
    let theme: PublicChatTheme
    let onTapNickname: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            if let s = sender {
                // v24（B1）：大 R 徽章前置（仅 Live 场景，对齐 H5 §9.6）
                if s.isActiveTycoon && theme.scene == .live { ActiveTycoonBadge(style: .bigRText, size: .small) }
                if let lv = s.userLevel, lv > 0 { UserLevelBadge(level: lv, size: .small) }
                if s.isVip {
                    VIPBadge(size: .small)
                } else if s.isNewUser {
                    LiveNewUserBadge()
                }
                nickname(s)
            }
            Text("Send")   // H5 L495/514: {{ $t('common.Send') }}
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
            PublicChatGiftIconBubble(iconURL: iconURL, count: count)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minHeight: 24)
        .frame(maxWidth: 249, alignment: .leading)
        .background(bubbleBackground)
    }

    @ViewBuilder
    private func nickname(_ sender: SenderProfile) -> some View {
        let label = Text(sender.nickname)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Color(red: 26/255, green: 1.0, blue: 205/255))
            .lineLimit(1)
        if let onTapNickname {
            Button(action: onTapNickname) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(sender.nickname))
        } else {
            label
        }
    }

    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.16))
    }
}

/// H5 attachType 197 首礼时刻公屏横幅。服务端主导背景与文案，iOS 仅做纯文本展示。
struct RowFirstGiftMoment: View {
    let sender: SenderProfile?
    let backgroundURL: String?
    let renderedText: String
    let giftIconURL: String?
    let isFirstGift: Bool
    let onTapNickname: (() -> Void)?

    var body: some View {
        HStack(spacing: isFirstGift ? 6 : 8) {
            leadingIcon
            if isFirstGift {
                firstGiftText
            } else {
                genericGiftText
            }
        }
        .padding(.horizontal, isFirstGift ? 10 : 8)
        .padding(.vertical, isFirstGift ? 5 : 7)
        .frame(maxWidth: 250, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 122/255, green: 48/255, blue: 112/255).opacity(0.72))
                if let raw = effectiveBackgroundURL, let url = URL(string: raw), !raw.isEmpty {
                    CachedAsyncImage(url: url, contentMode: .fill) { Color.clear }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if isFirstGift {
            CachedAsyncImage(
                url: URL(string: "https://img.hnhily.link/mstatic/live/first-gift-box.webp"),
                contentMode: .fit,
                persistent: true
            ) {
                Image(systemName: "gift.fill")
                    .foregroundColor(Color(red: 1, green: 230 / 255, blue: 0))
            }
            .frame(width: 40, height: 40)
        } else if let raw = giftIconURL, let url = URL(string: raw), !raw.isEmpty {
            CachedAsyncImage(url: url, contentMode: .fit, cdn: (.gift, .fit)) { Color.clear }
                .frame(width: 38, height: 38)
        } else {
            Image(systemName: "gift.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Color(red: 1, green: 220 / 255, blue: 104 / 255))
                .frame(width: 22, height: 22)
        }
    }

    private var firstGiftText: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                nickname(font: .system(size: 10, weight: .bold), color: Color(red: 1, green: 230 / 255, blue: 0))
                Text(" sent the first gift")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                giftIcon(size: 14)
            }
            Text("Kick off the first greeting moment")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var genericGiftText: some View {
        let label = HStack(spacing: 2) {
            Text(plainText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
            giftIcon(size: 20)
        }
        if let onTapNickname {
            Button(action: onTapNickname) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(sender?.nickname ?? ""))
        } else {
            label
        }
    }

    @ViewBuilder
    private func nickname(font: Font, color: Color) -> some View {
        let label = Text(sender?.nickname ?? "")
            .font(font)
            .foregroundColor(color)
            .lineLimit(1)
        if let onTapNickname {
            Button(action: onTapNickname) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(sender?.nickname ?? ""))
        } else {
            label
        }
    }

    @ViewBuilder
    private func giftIcon(size: CGFloat) -> some View {
        if let raw = giftIconURL, let url = URL(string: raw), !raw.isEmpty {
            CachedAsyncImage(url: url, contentMode: .fit, cdn: (.gift, .fit)) { Color.clear }
                .frame(width: size, height: size)
        }
    }

    private var effectiveBackgroundURL: String? {
        if isFirstGift { return "https://img.hnhily.link/mstatic/live/first-gift-public-bg.webp" }
        return backgroundURL
    }

    private var plainText: String {
        renderedText.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}
