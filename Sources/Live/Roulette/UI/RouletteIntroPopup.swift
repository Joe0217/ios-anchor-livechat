import SwiftUI

/// Roulette 首次引导 popup（对齐 H5 rpsIntroPopup.vue 3 卡片引导 + Skip/Next/Start）
///
/// 交互：3 张卡片顺序显示 → 最后一张点 "Start" 完成引导 → 触发 onFinish 回调
struct RouletteIntroPopup: View {
    @Binding var isPresented: Bool
    let onFinish: () -> Void

    @State private var currentCard: Int = 0
    private let totalCards = 3

    private var titles: [String] {
        [L10n.liveRoomRouletteIntroCard1Title,
         L10n.liveRoomRouletteIntroCard2Title,
         L10n.liveRoomRouletteIntroCard3Title]
    }
    private var bodies: [String] {
        [L10n.liveRoomRouletteIntroCard1Body,
         L10n.liveRoomRouletteIntroCard2Body,
         L10n.liveRoomRouletteIntroCard3Body]
    }

    var body: some View {
        if isPresented {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                    .contentShape(Rectangle())

                VStack(spacing: 20) {
                    // Card icon（每张不同：SF Symbol 占位；H 里程碑替换切图）
                    Image(systemName: cardIcon)
                        .font(.system(size: 56))
                        .foregroundColor(Color(hex: 0xFFBB02))
                        .frame(height: 80)

                    Text(titles[currentCard])
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)

                    Text(bodies[currentCard])
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    // 进度点
                    HStack(spacing: 8) {
                        ForEach(0..<totalCards, id: \.self) { idx in
                            Circle()
                                .fill(idx == currentCard ? Color(hex: 0xFFBB02) : Color.white.opacity(0.3))
                                .frame(width: 8, height: 8)
                        }
                    }
                    .padding(.top, 8)

                    // 按钮：Next / Start
                    Button {
                        if currentCard < totalCards - 1 {
                            currentCard += 1
                        } else {
                            onFinish()
                            withAnimation { isPresented = false }
                        }
                    } label: {
                        Text(currentCard < totalCards - 1
                             ? L10n.liveRoomRouletteIntroNext
                             : L10n.liveRoomRouletteIntroStart)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(hex: 0x6400D1), in: Capsule())
                    }
                    .padding(.horizontal, 40)
                }
                .padding(.vertical, 32)
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

    private var cardIcon: String {
        switch currentCard {
        case 0: return "gift.fill"
        case 1: return "dice.fill"
        case 2: return "sparkles"
        default: return "sparkles"
        }
    }
}
