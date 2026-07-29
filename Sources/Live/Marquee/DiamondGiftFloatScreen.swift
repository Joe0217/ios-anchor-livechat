import SwiftUI

/// 钻石盲盒飘屏（对齐 H5 diamond-gift-float-screen.vue）
///
/// 位置：屏幕顶部 10%
/// 动画：`offset(x:)` 从 -100vw → +100vw，5s ease-in-out（对齐 H5 translateX -110% → 110%）
struct DiamondGiftFloatScreen: View {
    @ObservedObject var queue: DiamondGiftFloatQueue
    @State private var offsetX: CGFloat = 0
    @State private var floatOpacity: CGFloat = 0
    @State private var currentItemId: UUID?
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                if let item = queue.current {
                    content(item, width: max(240, geo.size.width))
                        .offset(x: offsetX)
                        .opacity(floatOpacity)
                        .padding(.top, geo.size.height * 0.1)
                        .onAppear {
                            let direction: CGFloat = layoutDirection == .rightToLeft ? 1 : -1
                            offsetX = direction * geo.size.width * 1.1
                            floatOpacity = 0
                            currentItemId = item.id
                            Task { @MainActor in
                                await Task.yield()
                                guard currentItemId == item.id else { return }
                                withAnimation(.easeInOut(duration: 0.4)) {
                                    offsetX = 0
                                    floatOpacity = 1
                                }
                                try? await Task.sleep(nanoseconds: 4_200_000_000)
                                guard currentItemId == item.id else { return }
                                withAnimation(.easeInOut(duration: 0.4)) {
                                    offsetX = -direction * geo.size.width * 1.1
                                    floatOpacity = 0
                                }
                            }
                        }
                        .id(item.id)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .zIndex(20)
    }

    private func content(_ item: DiamondGiftFloatQueue.Item, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(item.senderNickname)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Color(hex: 0xFFF28E))
                .lineLimit(1)
                .frame(maxWidth: 80, alignment: .leading)
                .padding(.leading, 12)
                .padding(.trailing, 6)
            Text(L10n.diamondGiftSendAction)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .padding(.trailing, 6)
            Image("diamondGiftScreenIcon")
                .resizable().frame(width: 24, height: 24)
                .accessibilityHidden(true)
                .padding(.trailing, 4)
            if item.totalDiamonds > 0 {
                Text("x")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(hex: 0xFFF28E))
                    .padding(.trailing, 2)
                Text("\(item.totalDiamonds)")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundColor(Color(hex: 0xFFC83B))
                    .padding(.trailing, 12)
            }
        }
        .frame(width: width, height: 74, alignment: .center)
        .background(Image("diamondGiftFloatBackground").resizable().scaledToFill())
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

/// 直播间钻石福袋宿主。主播端只显示状态挂件、规则和获奖名单。
struct DiamondGiftHost: View {
    @ObservedObject var store: DiamondGiftStore

    var body: some View {
        ZStack {
            DiamondGiftHook(store: store)
            DiamondGiftRulesPopup(store: store)
            DiamondGiftWinnersPopup(store: store)
        }
    }
}

private struct DiamondGiftHook: View {
    @ObservedObject var store: DiamondGiftStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let gift = store.current {
                Button { store.rulesVisible = true } label: {
                    VStack(spacing: 1) {
                        ZStack(alignment: .topTrailing) {
                            AnimatedGIFView(
                                name: "diamond-gift-pendant",
                                fileExtension: "webp",
                                fallbackImageName: "diamondGiftPendant",
                                remoteURL: URL(string: "https://file.lovetravel.link/mstatic/dia-box/pendant-icons.webp"),
                                explicitDuration: 1.0
                            )
                                .frame(width: 34, height: 44)
                                .accessibilityHidden(true)
                            if store.queueLength > 1 {
                                Text("x\(store.queueLength)")
                                    .font(.system(size: 10, weight: .bold))
                                    .monospacedDigit()
                                    .padding(.horizontal, 5)
                                    .frame(minHeight: 18)
                                    .background(LinearGradient(colors: [Color(hex: 0xFF9438), Color(hex: 0xFF0090)],
                                                               startPoint: .leading, endPoint: .trailing), in: Capsule())
                                    .offset(x: 8, y: -5)
                            }
                        }
                        hookStatus(gift: gift, now: context.date)
                    }
                }
                .buttonStyle(.plain)
                .opacity(gift.state == .settled ? 0.5 : 1)
                .accessibilityLabel(Text(L10n.diamondGiftRulesTitle))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 126)
                .padding(.trailing, 12)
            }
        }
    }

    @ViewBuilder
    private func hookStatus(gift: DiamondGiftCurrent, now: Date) -> some View {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        if gift.state == .warming, gift.openAt > nowMs {
            Text(countdown(target: gift.openAt, now: nowMs))
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
        } else if gift.state != .settled {
            Text(L10n.diamondGiftGrab)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(hex: 0xD609FF))
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .background(Color(hex: 0xFFDD6E), in: Capsule())
        }
    }

    private func countdown(target: Int64, now: Int64) -> String {
        let remaining = max(0, Int(ceil(Double(target - now) / 1_000)))
        return String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }
}

private struct DiamondGiftRulesPopup: View {
    @ObservedObject var store: DiamondGiftStore

    var body: some View {
        PKPopupCard(isPresented: $store.rulesVisible, title: L10n.diamondGiftRulesTitle) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    rule(title: L10n.diamondGiftRulesATitle, bodies: [L10n.diamondGiftRulesA1])
                    rule(title: L10n.diamondGiftRulesBTitle, bodies: [L10n.diamondGiftRulesB1, L10n.diamondGiftRulesB2])
                    rule(title: L10n.diamondGiftRulesCTitle, bodies: [
                        L10n.diamondGiftRulesC1, L10n.diamondGiftRulesC2,
                        L10n.diamondGiftRulesC3, L10n.diamondGiftRulesC4
                    ])
                }
                .padding(12)
                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxHeight: 310)
        }
    }

    private func rule(title: String, bodies: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(.white.opacity(0.8))
            ForEach(bodies, id: \.self) { text in
                Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DiamondGiftWinnersPopup: View {
    @ObservedObject var store: DiamondGiftStore

    var body: some View {
        PKPopupCard(isPresented: $store.winnersVisible, title: L10n.diamondGiftWinnersTitle) {
            Group {
                if store.winnersLoading {
                    ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 140)
                } else if store.winners.isEmpty {
                    Text(L10n.diamondGiftNoWinners)
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, minHeight: 140)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(store.winners.enumerated()), id: \.element.id) { index, winner in
                                winnerRow(winner, rank: index + 1)
                            }
                        }
                    }
                    .frame(maxHeight: 328)
                }
            }
            .padding(.horizontal, 12)
            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func winnerRow(_ winner: DiamondGiftWinner, rank: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(rank)").font(.system(size: 15, weight: .bold)).foregroundStyle(rankColor(rank)).frame(width: 18)
            CachedAsyncImage(url: URL(string: winner.userAvatarURL ?? ""), contentMode: .fill) {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: 36, height: 36).clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                if winner.isTopShare {
                    HStack(spacing: 3) {
                        Image("diamondGiftMvp").resizable().scaledToFit().frame(width: 18, height: 18)
                        Text(L10n.diamondGiftTopShare).font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Color(hex: 0xFFCB47))
                }
                Text(winner.userName.isEmpty ? winner.id : winner.userName)
                    .font(.system(size: 14)).foregroundStyle(.white).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image("diamondGiftDiamond").resizable().frame(width: 16, height: 16)
            Text("\(winner.diamonds)").font(.system(size: 14, weight: .bold)).foregroundStyle(Color(hex: 0xFF33D3))
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.08)) }
    }

    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return Color(hex: 0xFFCB47)
        case 2: return Color(hex: 0xFF8A00)
        case 3: return Color(hex: 0x5B9CFF)
        default: return .white.opacity(0.5)
        }
    }
}
