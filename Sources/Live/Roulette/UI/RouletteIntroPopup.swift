import SwiftUI

/// Roulette 首次引导 popup（对齐 H5 [rpsIntroPopup.vue] 2 卡片 + Next 按钮）
///
/// - 卡 1：Wheel（对齐 H5 live.Wheel + live.Wheel intro desc）
/// - 卡 2：Rock Paper Scissors（对齐 H5 live.Rock Paper Scissors + live.RPS intro desc）
/// - 顶部标题："Live Interactive Game Rules"
///
/// **v24（B2）**：
/// - Autoplay 3.5s（对齐 H5 rpsIntroPopup.vue L11 `autoplay=3500 loop=true`）
/// - `reachedLast` sticky：滑到末尾一次后即使循环回到第 0 张，再点 Next 立即 finish
///   （对齐 H5 L34-36, 60-64 —— 治 loop 模式循环卡死）
/// - onDisappear / scenePhase !=.active 时停 autoplay Task 防后台 tick 耗电
struct RouletteIntroPopup: View {
    @Binding var isPresented: Bool
    let onFinish: () -> Void

    @State private var currentCard: Int = 0
    @State private var reachedLast: Bool = false     // v24 B2：sticky 到过末尾即退出
    @State private var autoplayTask: Task<Void, Never>? = nil
    @Environment(\.scenePhase) private var scenePhase
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

                    // 卡片区（横滑，H5 van-swipe autoplay=3500 loop=true；iOS 用 TabView 页 + 自动 Timer）
                    TabView(selection: $currentCard) {
                        ForEach(0..<totalCards, id: \.self) { idx in
                            card(idx: idx).tag(idx)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: 250)
                    .onChange(of: currentCard) { newValue in
                        // 用户手动滑或 autoplay 到最后一张时 sticky reachedLast
                        if newValue == totalCards - 1 { reachedLast = true }
                    }

                    // 进度点（对齐 H5 rpsIntroPopup.vue L118-123：可点击直接跳卡 + 活跃 dot 用白色）
                    HStack(spacing: 8) {
                        ForEach(0..<totalCards, id: \.self) { idx in
                            Circle()
                                .fill(idx == currentCard ? Color.white : Color.white.opacity(0.3))
                                .frame(width: 8, height: 8)
                                .contentShape(Circle().inset(by: -8))    // 热区扩到 24×24 便于点击
                                .onTapGesture {
                                    withAnimation { currentCard = idx }
                                    if idx == totalCards - 1 { reachedLast = true }
                                }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel(Text("Card \(idx + 1) of \(totalCards)"))
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
                            // v24（B2 M5 finding · .claude/rules/swiftui-button-plain-hitarea.md）：
                            // Button + .plain + Capsule 背景 → hit area 只覆盖 Text 字符 pixel；扩到整个 Capsule
                            .contentShape(Rectangle())
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
            .onAppear {
                // v24（B2 M4 finding）：overlay 常驻 + isPresented gate 下 @State 不会随开合重置；
                // 显式 reset 首屏卡 + reachedLast sticky，避免"再次触发引导"直接跳过 loop 卡片
                currentCard = 0
                reachedLast = false
                if scenePhase == .active { startAutoplay() }
            }
            .onDisappear { stopAutoplay() }
            .onChange(of: scenePhase) { phase in
                // 后台 / 非活跃时暂停 autoplay，回前台再启（对齐能耗友好模式）
                if phase == .active { startAutoplay() } else { stopAutoplay() }
            }
        }
    }

    private func startAutoplay() {
        stopAutoplay()
        autoplayTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(3500))
                guard !Task.isCancelled else { break }
                withAnimation { currentCard = (currentCard + 1) % totalCards }
            }
        }
    }

    private func stopAutoplay() {
        autoplayTask?.cancel()
        autoplayTask = nil
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
        // v24 B2：reachedLast sticky 后（用户已看完 loop 至少一轮），任何 Next 都退出
        // 对齐 H5 L60-64（loop=true 时防止循环卡死无法退出）
        if reachedLast || currentCard >= totalCards - 1 {
            reachedLast = true
            stopAutoplay()
            onFinish()
            withAnimation { isPresented = false }
        } else {
            withAnimation { currentCard += 1 }
        }
    }
}
