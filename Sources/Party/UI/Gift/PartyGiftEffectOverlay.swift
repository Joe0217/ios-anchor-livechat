import SwiftUI

/// 派对房礼物特效 UI。
///
/// H5 由 `gift-animator-normal`、`gift-animator-receiver` 和
/// `floating-message-manager` 三个组件组成；iOS 在房间根视图中用同一覆盖层承载中央礼物和飘屏，
/// 麦位效果则由 `PartyGiftReceiverEffect` 就近叠加在每个 seat 上。
struct PartyGiftEffectOverlay: View {
    @ObservedObject private var coordinator = PartyGiftEffectCoordinator.shared

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let gift = coordinator.centralGift,
                   let url = gift.staticImageURL {
                    PartyGiftZoomImage(id: gift.id, urlString: url, size: 150)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                PartyGiftFloatingStack(
                    messages: coordinator.floatingMessages,
                    width: min(360, max(0, proxy.size.width)),
                    travelDistance: max(0, proxy.size.width),
                    onAnimationFinished: { coordinator.finishFloatingAnimation(id: $0) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 300)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 叠在大/小麦位上的收礼动画。收礼人不在当前麦位时不渲染，协调器仍会自然推进下一条。
struct PartyGiftReceiverEffect: View {
    let userId: String?
    let size: CGFloat
    @ObservedObject private var coordinator = PartyGiftEffectCoordinator.shared

    var body: some View {
        if let userId,
           let gift = coordinator.receiverGift,
           gift.receiverUserIds.contains(userId),
           let url = gift.staticImageURL {
            PartyGiftZoomImage(id: gift.id, urlString: url, size: size)
                .id(gift.id)
        }
    }
}

private struct PartyGiftZoomImage: View {
    let id: UUID
    let urlString: String
    let size: CGFloat
    @State private var visible = false

    var body: some View {
        CachedAsyncImage(
            url: URL(string: urlString),
            contentMode: .fit,
            persistent: true,
            cdn: (.gift, .fit)
        ) {
            Color.clear
        }
        .frame(width: size, height: size)
        .scaleEffect(visible ? 1 : 0.01)
        .opacity(visible ? 1 : 0)
        .task(id: id) {
            visible = false
            try? await Task.sleep(nanoseconds: 10_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.45)) { visible = true }
            try? await Task.sleep(nanoseconds: 950_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.45)) { visible = false }
        }
    }
}

private struct PartyGiftFloatingStack: View {
    let messages: [PartyGiftEffectItem]
    let width: CGFloat
    let travelDistance: CGFloat
    let onAnimationFinished: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(messages) { message in
                PartyGiftFloatingRow(
                    message: message,
                    width: width,
                    travelDistance: travelDistance,
                    onAnimationFinished: onAnimationFinished
                )
            }
        }
        // H5 `floating-notification` 的 bottom transition = 300ms cubic-bezier(0.4, 0, 0.2, 1)。
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3), value: messages.map(\.id))
    }
}

private struct PartyGiftFloatingRow: View {
    let message: PartyGiftEffectItem
    let width: CGFloat
    let travelDistance: CGFloat
    let onAnimationFinished: (UUID) -> Void
    @State private var horizontalOffset: CGFloat
    @State private var opacity: Double

    init(
        message: PartyGiftEffectItem,
        width: CGFloat,
        travelDistance: CGFloat,
        onAnimationFinished: @escaping (UUID) -> Void
    ) {
        self.message = message
        self.width = width
        self.travelDistance = travelDistance
        self.onAnimationFinished = onAnimationFinished
        _horizontalOffset = State(initialValue: travelDistance)
        _opacity = State(initialValue: 0)
    }

    private var singleReceiver: PartyGiftEffectRecipient? {
        message.recipients.count == 1 ? message.recipients.first : nil
    }

    var body: some View {
        HStack(spacing: 7) {
            PartyGiftAvatar(urlString: message.senderAvatarURL, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                senderIdentity

                HStack(spacing: 3) {
                    Text(L10n.Party.giftEffectSendsTo)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                    recipientContent
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let url = message.staticImageURL {
                CachedAsyncImage(url: URL(string: url), contentMode: .fit, persistent: true, cdn: (.gift, .fit)) {
                    Color.clear
                }
                .frame(width: 32, height: 32)
            }
            Text("X \(message.giftCountTotal)")
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.86, blue: 0.31),
                            Color(red: 1.0, green: 0.95, blue: 0.54),
                            Color(red: 0.96, green: 0.57, blue: 0.03)
                        ],
                        startPoint: .trailing,
                        endPoint: .leading
                    )
                )
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(width: width, height: 48)
        .background {
            // H5 floating-message-item.vue 使用同一张横幅底图。
            CachedAsyncImage(
                url: URL(string: "https://img.hnhily.link/mstatic/party/float-message-bg.png"),
                contentMode: .fill,
                persistent: true
            ) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.66))
            }
        }
        .offset(x: horizontalOffset)
        .opacity(opacity)
        .task(id: message.id) {
            // H5 `floating-slide` keyframes:
            // 0%      translateX(100vw), opacity 0
            // 25%     translateX(0),     opacity 1
            // 75%     translateX(0),     opacity 1
            // 100%    translateX(-100vw), opacity 0
            horizontalOffset = travelDistance
            opacity = 0
            await Task.yield()
            guard !Task.isCancelled else { return }

            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.75)) {
                horizontalOffset = 0
                opacity = 1
            }
            do {
                try await Task.sleep(nanoseconds: 750_000_000)
                guard !Task.isCancelled else { return }
                try await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }

                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.75)) {
                    horizontalOffset = -travelDistance
                    opacity = 0
                }
                try await Task.sleep(nanoseconds: 750_000_000)
                guard !Task.isCancelled else { return }
                onAnimationFinished(message.id)
            } catch {
                return
            }
        }
    }

    @ViewBuilder
    private var senderIdentity: some View {
        HStack(spacing: 4) {
            Text(message.senderNickname ?? L10n.Party.defaultUser)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(maxWidth: 106, alignment: .leading)

            if message.senderUserType == 1,
               let level = message.senderLevel,
               level > 0 {
                UserLevelBadge(level: level, size: .small)
            }
            if message.senderUserType == 1, message.senderIsVip {
                VIPBadge(size: .small)
            }
            ForEach(Array(message.senderMedalURLs.enumerated()), id: \.offset) { medal in
                CachedAsyncImage(url: URL(string: medal.element), contentMode: .fit, persistent: true) {
                    Color.clear
                }
                .frame(width: 16, height: 16)
            }
            PartyRoleBadge(roomRoleType: message.senderRoomRoleType, size: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    @ViewBuilder
    private var recipientContent: some View {
        if let receiver = singleReceiver {
            Text(receiver.nickname ?? L10n.Party.defaultUser)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(red: 0.10, green: 1.0, blue: 0.80))
                .lineLimit(1)
        } else if !message.recipients.isEmpty {
            HStack(spacing: -5) {
                ForEach(Array(message.recipients.prefix(3))) { receiver in
                    PartyGiftAvatar(urlString: receiver.avatarURL, size: 20)
                        .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 1))
                }
            }
            Text(String(format: L10n.Party.giftEffectPeopleFormat, message.recipients.count))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(red: 0.10, green: 1.0, blue: 0.80))
        }
    }
}

private struct PartyGiftAvatar: View {
    let urlString: String?
    let size: CGFloat

    var body: some View {
        CachedAsyncImage(url: urlString.flatMap(URL.init(string:)), contentMode: .fill, persistent: false, cdn: (.avatarSmall, .fill)) {
            Circle().fill(Color.white.opacity(0.18))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
