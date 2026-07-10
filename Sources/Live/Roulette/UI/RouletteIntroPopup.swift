import SwiftUI

/// Roulette 首次引导 popup（对齐 H5 [rpsIntroPopup.vue] 2 卡片 + Next 按钮）
///
/// - 卡 1：Wheel（对齐 H5 live.Wheel + live.Wheel intro desc）
/// - 卡 2：Rock Paper Scissors（对齐 H5 live.Rock Paper Scissors + live.RPS intro desc）
/// - 顶部标题："Live Interactive Game Rules"
struct RouletteIntroPopup: View {
    @Binding var isPresented: Bool
    let onFinish: () -> Void

    @State private var currentCard: Int = 0
    private let totalCards = 2

    private var titles: [String] {
        [L10n.liveRoomRouletteIntroCard1Title,
         L10n.liveRoomRouletteIntroRpsTitle]
    }
    private var bodies: [String] {
        [L10n.liveRoomRouletteIntroCard1Body,
         L10n.liveRoomRouletteIntroRpsBody]
    }
    private var icons: [String] {
        ["gift.fill", "hand.raised.fill"]
    }

    var body: some View {
        if isPresented {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                    .contentShape(Rectangle())

                VStack(spacing: 16) {
                    // 顶部标题
                    Text(L10n.liveRoomRouletteIntroHeader)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)

                    // 卡片区（横滑，H5 用 van-swipe autoplay 3.5s；iOS 用 TabView(.page) 手动滑）
                    TabView(selection: $currentCard) {
                        ForEach(0..<totalCards, id: \.self) { idx in
                            card(idx: idx).tag(idx)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: 250)

                    // 进度点
                    HStack(spacing: 8) {
                        ForEach(0..<totalCards, id: \.self) { idx in
                            Circle()
                                .fill(idx == currentCard ? Color(hex: 0xFFBB02) : Color.white.opacity(0.3))
                                .frame(width: 8, height: 8)
                        }
                    }

                    // Next 按钮
                    Button(action: handleNext) {
                        Text(L10n.liveRoomRouletteIntroNext)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                LinearGradient(colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                                               startPoint: .leading, endPoint: .trailing),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 40)
                }
                .padding(.vertical, 24)
                .frame(maxWidth: 320)
                .background(
                    LinearGradient(colors: [Color(hex: 0x5300A1), Color(hex: 0x3800A0)],
                                   startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 20)
                )
                .padding(.horizontal, 24)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func card(idx: Int) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icons[idx])
                .font(.system(size: 48))
                .foregroundColor(Color(hex: 0xFFBB02))
                .frame(height: 60)
            Text(titles[idx])
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Text(bodies[idx])
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 20)
        }
    }

    private func handleNext() {
        if currentCard < totalCards - 1 {
            withAnimation { currentCard += 1 }
        } else {
            onFinish()
            withAnimation { isPresented = false }
        }
    }
}
