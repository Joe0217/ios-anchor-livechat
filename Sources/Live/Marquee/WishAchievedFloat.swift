import SwiftUI

/// 心愿达成飘屏（对齐 H5 `wishlist-complete-float.vue`）。
/// H5 使用顶部全宽横幅：右侧滑入，停留，左侧滑出，共 6 秒。
struct WishAchievedFloat: View {
    @ObservedObject var queue: WishAchievedQueue
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var phase: Phase = .initial

    private enum Phase {
        case initial
        case visible
        case leaving
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let item = queue.current {
                    content
                        .id(item.id)
                        .offset(x: offset(for: geo.size.width))
                        .padding(.top, geo.safeAreaInsets.top + 50)
                        .task(id: item.id) { await play(item) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .zIndex(20)
    }

    private var content: some View {
        HStack(spacing: 8) {
            Text(L10n.wishlistFloatComplete)
                .foregroundColor(Color(hex: 0xFFD243))
            Text(L10n.wishlistFloatThanks)
                .foregroundColor(.white)
        }
        .font(.system(size: 12, weight: .bold))
        .shadow(color: Color(hex: 0xFFDC64, opacity: 0.6), radius: 6)
        .frame(maxWidth: .infinity)
        .frame(height: 74)
        .background {
            CachedAsyncImage(
                url: URL(string: "https://file.lovetravel.link/mstatic/live/wishlist-nav-bg.webp"),
                contentMode: .fill,
                persistent: true
            ) {
                Color.black.opacity(0.45)
            }
        }
    }

    private func play(_ item: WishAchievedQueue.Item) async {
        phase = .initial
        await Task.yield()
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 1)) { phase = .visible }
        // H5: 1s enter + 4s stay + 1s leave = 6s total.
        guard await sleep(4), !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 1)) { phase = .leaving }
    }

    private func offset(for width: CGFloat) -> CGFloat {
        let direction: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
        switch phase {
        case .initial: return direction * width
        case .visible: return 0
        case .leaving: return -direction * width
        }
    }

    private func sleep(_ seconds: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

/// H5 `first-gift-float-screen.vue`：顶部 30% 的首礼/通用礼物横幅。
struct FirstGiftFloat: View {
    @ObservedObject var queue: FirstGiftFloatQueue
    @ObservedObject private var callStore = CallStore.shared
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var offsetX: CGFloat = 0
    @State private var opacity: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                if let item = queue.current, callStore.state == .idle {
                    banner(item)
                        // H5 outer layer has 8px side padding and the banner itself is max-width 330px.
                        .frame(maxWidth: min(330, max(0, geo.size.width - 16)))
                        .offset(x: offsetX)
                        .opacity(opacity)
                        .padding(.top, geo.size.height * 0.30)
                        .id(item.id)
                        .onAppear { animate(item, width: geo.size.width) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .zIndex(21)
    }

    private func banner(_ item: FirstGiftFloatQueue.Item) -> some View {
        HStack(spacing: 10) {
            if item.isFirstGift {
                CachedAsyncImage(
                    url: URL(string: "https://img.hnhily.link/mstatic/live/first-gift-box.webp"),
                    contentMode: .fit,
                    persistent: true
                ) {
                    Image(systemName: "gift.fill").foregroundColor(Color(hex: 0xFFE600))
                }
                .frame(width: 52, height: 52)
            } else if let raw = item.giftImageURL ?? item.giftSmallImageURL,
                      let url = URL(string: raw) {
                CachedAsyncImage(url: url, contentMode: .fit, cdn: (.gift, .fit)) { Color.clear }
                    .frame(width: 38, height: 38)
            }

            firstGiftText(item)
        }
        .padding(.leading, 14)
        .padding(.trailing, item.isFirstGift ? 14 : 16)
        .padding(.vertical, item.isFirstGift ? 8 : 10)
        .frame(minHeight: item.isFirstGift ? 60 : 64)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: [Color(hex: 0xFF6DAE), Color(hex: 0xC86BFF)],
                                         startPoint: .leading, endPoint: .trailing))
                if let raw = item.backgroundURL, let url = URL(string: raw) {
                    CachedAsyncImage(url: url, contentMode: .fill) { Color.clear }
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    @ViewBuilder
    private func firstGiftText(_ item: FirstGiftFloatQueue.Item) -> some View {
        let text = item.renderedText.isEmpty ? item.nickname : item.renderedText
        VStack(alignment: .leading, spacing: 2) {
            if item.isFirstGift {
                FirstGiftHeadline(
                    nickname: item.nickname,
                    giftURL: item.giftSmallImageURL ?? item.giftImageURL
                )
                Text(L10n.liveGiftFirstGiftKick)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    highlightedGiftText(text, nickname: item.nickname)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(2)
                    if let raw = item.giftSmallImageURL ?? item.giftImageURL,
                       let url = URL(string: raw) {
                        CachedAsyncImage(url: url, contentMode: .fit, cdn: (.gift, .fit)) { Color.clear }
                            .frame(width: 14, height: 14)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func highlightedGiftText(_ text: String, nickname: String) -> Text {
        let streamer = text.contains("Streamer") ? "Streamer" : L10n.liveGiftFirstGiftStreamer
        let spans = [
            (nickname, Color(hex: 0xFFE600)),
            (streamer, Color(hex: 0x1AFFCD)),
        ].compactMap { value, color -> (Range<String.Index>, Color)? in
            guard !value.isEmpty, let range = text.range(of: value) else { return nil }
            return (range, color)
        }.sorted { $0.0.lowerBound < $1.0.lowerBound }
        guard !spans.isEmpty else {
            return Text(text).foregroundColor(.white)
        }
        var result = Text("")
        var cursor = text.startIndex
        for (range, color) in spans where range.lowerBound >= cursor {
            result = result
                + Text(String(text[cursor..<range.lowerBound])).foregroundColor(.white)
                + Text(String(text[range])).foregroundColor(color)
            cursor = range.upperBound
        }
        return result + Text(String(text[cursor...])).foregroundColor(.white)
    }

    private func animate(_ item: FirstGiftFloatQueue.Item, width: CGFloat) {
        let direction: CGFloat = layoutDirection == .rightToLeft ? 1 : -1
        offsetX = direction * width * 1.1
        opacity = 0
        Task { @MainActor in
            await Task.yield()
            guard queue.current?.id == item.id else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                offsetX = 0
                opacity = 1
            }
            try? await Task.sleep(nanoseconds: 4_600_000_000)
            guard queue.current?.id == item.id else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                offsetX = -direction * width * 1.1
                opacity = 0
            }
        }
    }
}

/// H5 `first-gift-moment-banner.vue` keeps the gift image inline with a localized
/// `{name}/{streamer}/{gift}` sentence. Parsing the placeholders preserves Arabic
/// and Turkish word order instead of hard-coding the English sequence.
private struct FirstGiftHeadline: View {
    private enum Token: Hashable, Identifiable {
        case text(String)
        case nickname
        case streamer
        case gift

        var id: String {
            switch self {
            case let .text(value): return "text:\(value)"
            case .nickname: return "nickname"
            case .streamer: return "streamer"
            case .gift: return "gift"
            }
        }
    }

    let nickname: String
    let giftURL: String?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tokens) { token in
                switch token {
                case let .text(value):
                    Text(value).foregroundColor(.white)
                case .nickname:
                    Text(nickname)
                        .foregroundColor(Color(hex: 0xFFE600))
                        .lineLimit(1)
                        .frame(maxWidth: 120, alignment: .leading)
                case .streamer:
                    Text(L10n.liveGiftFirstGiftStreamer).foregroundColor(Color(hex: 0x1AFFCD))
                case .gift:
                    if let giftURL, let url = URL(string: giftURL) {
                        CachedAsyncImage(url: url, contentMode: .fit, cdn: (.gift, .fit)) { Color.clear }
                            .frame(width: 18, height: 18)
                    }
                }
            }
        }
        .font(.system(size: 13, weight: .bold))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private var tokens: [Token] {
        let placeholders: [(String, Token)] = [
            ("{name}", .nickname),
            ("{streamer}", .streamer),
            ("{gift}", .gift),
        ]
        var remaining = L10n.liveGiftFirstGiftHeadline
        var result: [Token] = []
        while !remaining.isEmpty {
            guard let match = placeholders.compactMap({ placeholder, token -> (Range<String.Index>, Token)? in
                remaining.range(of: placeholder).map { ($0, token) }
            }).min(by: { $0.0.lowerBound < $1.0.lowerBound }) else {
                result.append(.text(remaining))
                break
            }
            let prefix = String(remaining[..<match.0.lowerBound])
            if !prefix.isEmpty { result.append(.text(prefix)) }
            result.append(match.1)
            remaining = String(remaining[match.0.upperBound...])
        }
        return result
    }
}

/// H5 `guardianBroadcastNotice.vue`：守护开通/续费顶部广播。
struct GuardianBroadcastFloat: View {
    @ObservedObject var queue: GuardianBroadcastQueue
    @State private var offsetX: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                if let item = queue.current {
                    content(item)
                        .frame(width: min(345, geo.size.width - 30), height: 68)
                        .offset(x: offsetX)
                        .padding(.top, geo.safeAreaInsets.top + 70)
                        .id(item.id)
                        .onAppear { animate(item, width: geo.size.width) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .zIndex(21)
    }

    private func content(_ item: GuardianBroadcastQueue.Item) -> some View {
        let parts = guardianMessageParts(item)
        let message = Text(parts.before)
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.white)
            + Text(item.anchorNickname)
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(Color(hex: 0xF2FF00))
            + Text(parts.after)
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.white)
        return HStack(spacing: 0) {
            AvatarView(urlString: item.avatarURL, size: 20, kind: .user)
                .padding(.trailing, 6)
            Text(truncated(item.nickname))
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Color(hex: 0x1AFFCD))
                .lineLimit(1)
                .padding(.trailing, 4)
            message
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, 50)
        .padding(.trailing, 16)
        .background {
            CachedAsyncImage(url: backgroundURL(for: item.levelCode), contentMode: .fill, persistent: true) {
                LinearGradient(colors: [Color(hex: 0x7141B4), Color(hex: 0x392275)],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 30))
        .shadow(color: Color(hex: 0x785AC8, opacity: 0.4), radius: 5)
    }

    private func animate(_ item: GuardianBroadcastQueue.Item, width: CGFloat) {
        offsetX = width
        Task { @MainActor in
            await Task.yield()
            guard queue.current?.id == item.id else { return }
            withAnimation(.easeInOut(duration: 1)) { offsetX = 0 }
            // H5: 1s enter + 3s stay + 1s leave. The queue keeps this item for 5 seconds.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard queue.current?.id == item.id else { return }
            withAnimation(.easeInOut(duration: 1)) { offsetX = -width }
        }
    }

    private func backgroundURL(for level: Int) -> URL? {
        let name: String
        switch level {
        case 3: name = "gold"
        case 2: name = "silver"
        default: name = "bronze"
        }
        return URL(string: "https://img.hnhily.link/mstatic/guardian/bg_guardian_broadcast_\(name).webp")
    }

    private func guardianLevelName(_ level: Int) -> String {
        switch level {
        case 3: return L10n.guardianLevelGold
        case 2: return L10n.guardianLevelSilver
        default: return L10n.guardianLevelBronze
        }
    }

    private func guardianMessageParts(_ item: GuardianBroadcastQueue.Item) -> (before: String, after: String) {
        let anchorMarker = "{anchor}"
        let message = L10n.guardianBroadcastBecame
            .replacingOccurrences(of: "{level}", with: guardianLevelName(item.levelCode))
        guard let range = message.range(of: anchorMarker) else {
            return (message, "")
        }
        return (
            String(message[..<range.lowerBound]),
            String(message[range.upperBound...])
        )
    }

    private func truncated(_ nickname: String) -> String {
        let characters = Array(nickname)
        return characters.count > 5 ? String(characters.prefix(5)) + "..." : nickname
    }
}

/// H5 `g-fullServiceNotice.vue`：幸运礼物中奖的全服公告。
struct LuckyGiftNoticeFloat: View {
    @ObservedObject var queue: LuckyGiftNoticeQueue
    @State private var phase: Phase = .initial

    private enum Phase {
        case initial
        case staying
        case leaving
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                if let item = queue.current {
                    notice(item)
                        .frame(width: min(345, geo.size.width - 30), height: 32)
                        .offset(x: offset(for: geo.size.width))
                        .padding(.top, geo.safeAreaInsets.top + 70)
                        .id(item.id)
                        .task(id: item.id) { await play(item) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .zIndex(21)
    }

    private func notice(_ item: LuckyGiftNoticeQueue.Item) -> some View {
        ZStack(alignment: .leading) {
            CachedAsyncImage(url: URL(string: item.backgroundURL), contentMode: .fill, persistent: true) {
                LinearGradient(colors: [Color(hex: 0x684961), Color(hex: 0x4C2E54)],
                               startPoint: .leading, endPoint: .trailing)
            }
            .offset(y: -22)

            Image("luckyGiftNoticeBadge")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .padding(.leading, 20)

            LuckyGiftNoticeText(item: item)
                .padding(.leading, 44)
                .padding(.trailing, 20)
        }
        .clipShape(RoundedRectangle(cornerRadius: 30))
    }

    private func play(_ item: LuckyGiftNoticeQueue.Item) async {
        phase = .initial
        await Task.yield()
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 1)) { phase = .staying }
        // H5: 1s enter + 5s stay + 1s leave = 7s total.
        guard await sleep(5) else { return }
        withAnimation(.easeInOut(duration: 1)) { phase = .leaving }
    }

    private func offset(for width: CGFloat) -> CGFloat {
        switch phase {
        case .initial: return width
        case .staying: return 0
        case .leaving: return -width
        }
    }

    private func sleep(_ seconds: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

private struct LuckyGiftNoticeText: View {
    let item: LuckyGiftNoticeQueue.Item
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 4) {
                AvatarView(urlString: item.senderAvatarURL, size: 16, kind: .user)
                Text(item.senderNickname)
                    .foregroundColor(Color(hex: 0x1AFFCD))
                    .frame(maxWidth: 36, alignment: .leading)
                    .lineLimit(1)
                Text("won")
                Text("\(item.reward)")
                    .foregroundColor(Color(hex: 0xF2FF00))
                Image("luckyGiftNoticeDiamond")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                Text("with lucky gifts in")
                AvatarView(urlString: item.receiverAvatarURL, size: 16, kind: .anchor)
                Text(item.receiverNickname)
                    .foregroundColor(Color(hex: 0xFE00DE))
                    .frame(maxWidth: 36, alignment: .leading)
                    .lineLimit(1)
                Text("Live!")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: offset)
            .task(id: item.id) {
                offset = 0
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                    offset = -max(geo.size.width, 1)
                }
            }
        }
        .clipped()
    }
}

/// H5 `liveRoomFloatTips.vue`：每次收礼展示的左侧收礼浮窗。
struct LiveGiftFloat: View {
    @ObservedObject var queue: LiveGiftFloatQueue
    @State private var visible = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let item = queue.current {
                    content(item)
                        .opacity(visible ? 1 : 0)
                        .scaleEffect(visible ? 1 : 0.86, anchor: .leading)
                        .padding(.leading, 15)
                        .padding(.top, geo.size.height * 0.40)
                        .id(item.id)
                        .task(id: item.id) {
                            visible = false
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                visible = true
                            }
                        }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .zIndex(20)
    }

    private func content(_ item: LiveGiftFloatQueue.Item) -> some View {
        HStack(spacing: 5) {
            AvatarView(urlString: item.senderAvatarURL, size: 32, kind: .user)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.senderNickname)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(L10n.publicScreenSentAction)
                    Text(item.receiverNickname)
                        .foregroundColor(Color(hex: 0xF7FF81))
                        .lineLimit(1)
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
            }
            .frame(width: 96, alignment: .leading)
            if let raw = item.giftImageURL, let url = URL(string: raw) {
                CachedAsyncImage(url: url, contentMode: .fit, cdn: (.gift, .fit)) { Color.clear }
                    .frame(width: 32, height: 32)
            }
            Text("x \(item.giftCount)")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(width: 30, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .frame(width: 216, height: 40, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(hex: 0xFF8C88), Color(hex: 0xEE5C97, opacity: 0.6), Color(hex: 0xED9A52, opacity: 0.1)],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: Capsule()
        )
    }
}
