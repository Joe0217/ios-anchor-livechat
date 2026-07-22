import SwiftUI
import UIKit

/// 付费弹幕飘屏。挂在公屏顶部，布局与 H5 `BulletFloatManager` 一致。
struct PaidBulletFloat: View {
    @ObservedObject var queue: PaidBulletQueue
    @State private var phase: AnimPhase = .initial

    private enum AnimPhase: Equatable {
        case initial
        case entering
        case staying
        case leaving
    }

    private enum Metrics {
        static let pillWidth: CGFloat = 275
        static let pillHeight: CGFloat = 44
        static let avatarSize: CGFloat = 30
        static let dislikeSize: CGFloat = 28
        static let leadingPadding: CGFloat = 7
        static let trailingPadding: CGFloat = 22
        static let gap: CGFloat = 6
        static let messageGap: CGFloat = 40
        static let scrollSpeed: CGFloat = 60
        static let enterDuration: TimeInterval = 0.5
        static let leaveDuration: TimeInterval = 0.5
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if let item = queue.current {
                    content(item)
                        .offset(x: offset(for: geo.size.width))
                        .id(item.id)
                        .task(id: item.id) {
                            await play(item)
                        }
                }
            }
            .frame(width: geo.size.width, height: Metrics.pillHeight, alignment: .leading)
            .clipped()
        }
        .frame(height: Metrics.pillHeight)
    }

    private func play(_ item: PaidBulletQueue.Item) async {
        phase = .initial
        await Task.yield()
        guard !Task.isCancelled else { return }

        withAnimation(.easeOut(duration: Metrics.enterDuration)) {
            phase = .entering
        }
        guard await sleep(Metrics.enterDuration) else { return }

        phase = .staying
        guard await sleep(stayDuration(for: item)) else { return }

        withAnimation(.easeIn(duration: Metrics.leaveDuration)) {
            phase = .leaving
        }
        guard await sleep(Metrics.leaveDuration), !Task.isCancelled else { return }
        queue.completePlayback(of: item)
    }

    private func sleep(_ duration: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func offset(for width: CGFloat) -> CGFloat {
        switch phase {
        case .initial: return width
        case .entering, .staying: return 0
        case .leaving: return -width
        }
    }

    private func content(_ item: PaidBulletQueue.Item) -> some View {
        let messageWidth = messageViewportWidth(for: item)
        let canDislike = queue.canDislike(item)

        return HStack(spacing: Metrics.gap) {
            // H5 广播缺 senderAvatar 时使用 assets/icon/head.png；iOS 的 defaultAvatar 为同源资源。
            AvatarView(urlString: item.senderAvatarUrl, size: Metrics.avatarSize, kind: .anchor)
                .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 1))

            HStack(spacing: 0) {
                Text(displayNickname(item.senderNickname))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(hex: 0xEEFF00))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(":")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(hex: 0xEEFF00))
                    .padding(.trailing, 4)
                    .fixedSize(horizontal: true, vertical: false)
                PaidBulletMessageMarquee(
                    content: item.content,
                    isActive: phase == .staying,
                    viewportWidth: messageWidth
                )
                .frame(width: messageWidth, height: 16)
            }

            if canDislike {
                Button {
                    Task { @MainActor in
                        do {
                            try await queue.dislike(item)
                        } catch {
                            AppToastCenter.shared.show(L10n.paidBulletDislikeFailed)
                        }
                    }
                } label: {
                    CachedAsyncImage(
                        url: URL(string: "https://file.lovetravel.link/mstatic/bullet/dislike-icon.webp"),
                        contentMode: .fit,
                        persistent: true
                    ) {
                        Image(systemName: "hand.thumbsdown.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .opacity(queue.isDisliked(item) ? 0.45 : 1)
                    .frame(width: Metrics.dislikeSize, height: Metrics.dislikeSize)
                }
                .buttonStyle(.plain)
                .disabled(queue.isDisliked(item) || queue.isDisliking(item))
                .accessibilityLabel(Text(L10n.paidBulletDislike))
            }
        }
        .padding(.leading, Metrics.leadingPadding)
        .padding(.trailing, Metrics.trailingPadding)
        .frame(width: Metrics.pillWidth, height: Metrics.pillHeight)
        .background {
            CachedAsyncImage(url: backgroundURL(for: item.scope), contentMode: .fill, persistent: true) {
                Color.clear
            }
            .frame(width: Metrics.pillWidth, height: Metrics.pillHeight)
            .allowsHitTesting(false)
        }
    }

    private func backgroundURL(for scope: PaidBulletQueue.Scope) -> URL? {
        let path: String
        switch scope {
        case .room: path = "publish-bg.webp"
        case .country: path = "country-bg.webp"
        case .global: path = "global-bg.webp"
        }
        return URL(string: "https://file.lovetravel.link/mstatic/bullet/\(path)")
    }

    private func displayNickname(_ nickname: String) -> String {
        let characters = Array(nickname)
        guard characters.count > 6 else { return nickname }
        return String(characters.prefix(6)) + "…"
    }

    private func messageViewportWidth(for item: PaidBulletQueue.Item) -> CGFloat {
        let nicknameWidth = textWidth(displayNickname(item.senderNickname), weight: .bold)
        let colonWidth = textWidth(":", weight: .bold) + 4
        let dislikeWidth = queue.canDislike(item) ? Metrics.gap + Metrics.dislikeSize : 0
        let fixedWidth = Metrics.leadingPadding + Metrics.trailingPadding
            + Metrics.avatarSize + Metrics.gap + nicknameWidth + colonWidth + dislikeWidth
        return max(1, Metrics.pillWidth - fixedWidth)
    }

    private func stayDuration(for item: PaidBulletQueue.Item) -> TimeInterval {
        let textWidth = textWidth(item.content, weight: .regular)
        let viewportWidth = messageViewportWidth(for: item)
        guard textWidth - viewportWidth > 1 else { return item.stayDuration }
        let cycle = max(1.5, Double((textWidth + Metrics.messageGap) / Metrics.scrollSpeed))
        return max(item.stayDuration, cycle)
    }

    private func textWidth(_ text: String, weight: UIFont.Weight) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 13, weight: weight)]).width
    }
}

private struct PaidBulletMessageMarquee: View {
    let content: String
    let isActive: Bool
    let viewportWidth: CGFloat

    private let messageGap: CGFloat = 40
    private let scrollSpeed: CGFloat = 60
    @State private var offset: CGFloat = 0

    private var contentWidth: CGFloat {
        (content as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 13)]).width
    }

    private var isOverflowing: Bool { contentWidth - viewportWidth > 1 }
    private var loopDistance: CGFloat { contentWidth + messageGap }
    private var loopDuration: TimeInterval { max(1.5, Double(loopDistance / scrollSpeed)) }

    var body: some View {
        HStack(spacing: messageGap) {
            messageText
            if isOverflowing { messageText }
        }
        .offset(x: offset)
        .frame(width: viewportWidth, alignment: .leading)
        .clipped()
        .onAppear(perform: updateAnimation)
        .onChange(of: isActive) { _ in updateAnimation() }
        .onChange(of: content) { _ in updateAnimation() }
    }

    private var messageText: some View {
        Text(content)
            .font(.system(size: 13))
            .foregroundColor(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func updateAnimation() {
        guard isActive, isOverflowing else {
            offset = 0
            return
        }
        offset = 0
        withAnimation(.linear(duration: loopDuration).repeatForever(autoreverses: false)) {
            offset = -loopDistance
        }
    }
}
