import SwiftUI

/// H5 活动中奖公屏：带背景图的活动卡与不带图的紧凑通知共用同一数据模型。
struct RowWinnerBroadcast: View {
    let sender: SenderProfile?
    let activityName: String
    let quantity: Int?
    let messageImageURL: String?
    let prizeImageURL: String?
    let joinCTA: String?
    let avatar: String?
    let validDays: Int?
    let nicknameColorHex: String?
    let prizeColorHex: String?
    let cardType: String?
    let theme: PublicChatTheme
    let onTapNickname: (() -> Void)?
    let onTap: (() -> Void)?

    @ViewBuilder
    var body: some View {
        if let onTap {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let imageURL = messageImageURL, !imageURL.isEmpty {
            richForm(imageURL: imageURL)
        } else {
            simpleForm
        }
    }

    private func richForm(imageURL: String) -> some View {
        ZStack(alignment: .topLeading) {
            if let url = URL(string: imageURL) {
                CachedAsyncImage(url: url, contentMode: .fill) {
                    Color.black.opacity(0.3)
                }
                .frame(maxWidth: 250)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    avatarView
                    richNickname
                    Text("Winner Got")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                    prizeIcon
                    Text(activityName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(activityColor)
                }
                if let detail = prizeDetail {
                    Text(detail)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(prizeColor)
                }
                HStack { Spacer(minLength: 0); joinButton(height: 28) }
            }
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var simpleForm: some View {
        HStack(spacing: 4) {
            WinnerBroadcastMarquee(
                nickname: sender?.nickname ?? "",
                nicknameColor: color(hex: nicknameColorHex, fallback: Color(hex: 0xFFD84E)),
                activityName: activityName,
                activityColor: activityColor,
                detail: prizeDetail,
                detailColor: prizeColor,
                prizeImageURL: prizeImageURL
            )
            joinButton(height: 17)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: 249, minHeight: 26)
        .background(simpleBackground, in: RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(Color(red: 1, green: 210 / 255, blue: 80 / 255).opacity(0.4), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var avatarView: some View {
        if let avatarURL = avatar ?? sender?.avatarURL, !avatarURL.isEmpty {
            AvatarView(urlString: avatarURL, size: 20, kind: .user)
        }
    }

    @ViewBuilder
    private var prizeIcon: some View {
        if let raw = prizeImageURL, let url = URL(string: raw), !raw.isEmpty {
            CachedAsyncImage(url: url, contentMode: .fit, cdn: (.gift, .fit)) { Color.clear }
                .frame(width: 14, height: 14)
        }
    }

    @ViewBuilder
    private func joinButton(height: CGFloat) -> some View {
        if let joinCTA, let url = URL(string: joinCTA), !joinCTA.isEmpty {
            CachedAsyncImage(url: url, contentMode: .fit) { Color.clear }
                .frame(width: height >= 28 ? 120 : nil, height: height)
        } else {
            Text("Join")
                .font(.system(size: height >= 28 ? 10 : 9, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .frame(minHeight: height)
                .background(Color(red: 1.0, green: 148 / 255, blue: 56 / 255), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var richNickname: some View {
        nickname(fontSize: 13, fallback: Color(red: 26 / 255, green: 1, blue: 205 / 255))
    }

    @ViewBuilder
    private var simpleNickname: some View {
        nickname(fontSize: 12, fallback: Color(red: 1, green: 216 / 255, blue: 78 / 255))
    }

    @ViewBuilder
    private func nickname(fontSize: CGFloat, fallback: Color) -> some View {
        let label = Text(sender?.nickname ?? "")
            .font(.system(size: fontSize, weight: .bold))
            .foregroundColor(color(hex: nicknameColorHex, fallback: fallback))
            .lineLimit(1)
        if let onTapNickname {
            Button(action: onTapNickname) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(sender?.nickname ?? ""))
        } else {
            label
        }
    }

    private var prizeDetail: String? {
        if let validDays, validDays > 0 { return "* \(validDays) Days" }
        if let quantity, quantity > 0 { return "* \(quantity)" }
        return nil
    }

    private var activityColor: Color {
        Color(red: 1, green: 216 / 255, blue: 78 / 255)
    }

    private var prizeColor: Color {
        color(hex: prizeColorHex, fallback: .white)
    }

    private var simpleBackground: LinearGradient {
        return LinearGradient(
            colors: [
                Color(red: 1, green: 180 / 255, blue: 0).opacity(0.25),
                Color(red: 1, green: 80 / 255, blue: 180 / 255).opacity(0.25),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func color(hex: String?, fallback: Color) -> Color {
        guard var hex else { return fallback }
        hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return fallback }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// H5 `winner-broadcast-text`: no-image broadcasts reserve a 249×26 strip and
/// continuously move the full message right-to-left instead of truncating it.
private struct WinnerBroadcastMarquee: View {
    let nickname: String
    let nicknameColor: Color
    let activityName: String
    let activityColor: Color
    let detail: String?
    let detailColor: Color
    let prizeImageURL: String?

    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 4) {
                if let prizeImageURL, let url = URL(string: prizeImageURL) {
                    CachedAsyncImage(url: url, contentMode: .fit, cdn: (.gift, .fit)) { Color.clear }
                        .frame(width: 14, height: 14)
                }
                Text(nickname).fontWeight(.bold).foregroundColor(nicknameColor)
                Text("Winner Got")
                Text(activityName).fontWeight(.bold).foregroundColor(activityColor)
                if let detail { Text(detail).foregroundColor(detailColor) }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .background {
                GeometryReader { textProxy in
                    Color.clear.preference(key: WinnerBroadcastTextWidthKey.self, value: textProxy.size.width)
                }
            }
            .offset(x: offset)
            .onPreferenceChange(WinnerBroadcastTextWidthKey.self) { textWidth = $0 }
            .task(id: "\(nickname)|\(activityName)|\(detail ?? "")|\(proxy.size.width)|\(textWidth)") {
                guard textWidth > 0 else { return }
                offset = textWidth
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                    offset = -textWidth
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
    }
}

private struct WinnerBroadcastTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
