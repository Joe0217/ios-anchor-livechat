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
/// - 遵循 `.claude/rules/banner-carousel-looping.md`：手动和自动分页均可连续跨首尾循环
struct RouletteIntroPopup: View {
    @Binding var isPresented: Bool
    let onFinish: () -> Void

    /// 逻辑卡片下标，用于圆点和完成状态；与 Pager 的哨兵页下标分离。
    @State private var currentCard: Int = 0
    /// 0=末卡副本，1...n=真实卡，n+1=首卡副本。
    @State private var selectedPage: Int = 1
    @State private var reachedLast: Bool = false     // v24 B2：sticky 到过末尾即退出
    @State private var autoplayEnabled = true
    @State private var pageChangeOrigin: PageChangeOrigin?
    @State private var manualInteractionGeneration = 0
    @State private var isManualDragInProgress = false
    @Environment(\.scenePhase) private var scenePhase
    private let totalCards = 2

    private enum PageChangeOrigin {
        case automatic
        case loopCorrection
    }

    private struct AutoplayKey: Hashable {
        let enabled: Bool
        let isSceneActive: Bool
    }

    private struct ResumeKey: Hashable {
        let interactionGeneration: Int
        let isSceneActive: Bool
    }

    private var titles: [String] {
        [L10n.liveRoomRouletteIntroCard1Title,
         L10n.liveRoomRouletteIntroRpsTitle]
    }
    private var bodies: [String] {
        [L10n.liveRoomRouletteIntroCard1Body,
         L10n.liveRoomRouletteIntroRpsBody]
    }
    private var icons: [String] {
        ["rouletteIntroWheel", "rouletteIntroRps"]
    }

    var body: some View {
        if isPresented {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                    .contentShape(Rectangle())

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                        .frame(height: 60)

                    Text(L10n.liveRoomRouletteIntroHeader)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    Spacer(minLength: 0)
                        .frame(height: 20)

                    TabView(selection: $selectedPage) {
                        // 首尾镜像页保证用户可从任一方向连续滑动；到达后无动画归位。
                        ForEach(0..<(totalCards + 2), id: \.self) { page in
                            let cardIndex = (page - 1 + totalCards) % totalCards
                            card(idx: cardIndex).tag(page)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: 250)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .frame(height: 270)
                    .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 20)
                    .simultaneousGesture(manualPagingGesture)
                    .onChange(of: selectedPage) { page in
                        handlePageChange(page)
                    }

                    HStack(spacing: 5) {
                        ForEach(0..<totalCards, id: \.self) { idx in
                            Circle()
                                .fill(idx == currentCard ? Color.white : Color.white.opacity(0.3))
                                .frame(width: 4, height: 4)
                                .frame(width: 24, height: 24)
                                .contentShape(Circle())
                                .onTapGesture {
                                    withAnimation { selectedPage = idx + 1 }
                                    if idx == totalCards - 1 { reachedLast = true }
                                }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel(Text("Card \(idx + 1) of \(totalCards)"))
                        }
                    }
                    .padding(.top, 1)
                    .padding(.bottom, 7)

                    Button(action: handleNext) {
                        Text(L10n.liveRoomRouletteIntroNext)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 263, height: 44)
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
                }
                .frame(maxWidth: 323)
                .frame(height: 473, alignment: .top)
                .background(
                    Image("rouletteIntroBackground")
                        .resizable()
                        .scaledToFill()
                )
                .overlay(alignment: .top) {
                    Image("rouletteIntroGame")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 93, height: 93)
                        .offset(y: -40)
                }
                .padding(.horizontal, 16)
            }
            .transition(.opacity)
            .onAppear {
                // v24（B2 M4 finding）：overlay 常驻 + isPresented gate 下 @State 不会随开合重置；
                // 显式 reset 首屏卡 + reachedLast sticky，避免"再次触发引导"直接跳过 loop 卡片
                currentCard = 0
                selectedPage = 1
                reachedLast = false
                autoplayEnabled = true
                manualInteractionGeneration = 0
            }
            .task(id: AutoplayKey(
                enabled: autoplayEnabled,
                isSceneActive: scenePhase == .active
            )) {
                guard autoplayEnabled, scenePhase == .active else { return }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: 3_500_000_000)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    advanceCard()
                }
            }
            .task(id: ResumeKey(
                interactionGeneration: manualInteractionGeneration,
                isSceneActive: scenePhase == .active
            )) {
                guard manualInteractionGeneration > 0, scenePhase == .active else { return }
                do {
                    try await Task.sleep(nanoseconds: 3_500_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled, scenePhase == .active else { return }
                autoplayEnabled = true
            }
        }
    }

    private func handlePageChange(_ page: Int) {
        let origin = pageChangeOrigin
        pageChangeOrigin = nil
        if origin == nil {
            pauseAutoplayForManualInteraction()
        }

        if page == 0 {
            currentCard = totalCards - 1
            reachedLast = true
            resetLoopPage(from: page, to: totalCards)
        } else if page == totalCards + 1 {
            currentCard = 0
            resetLoopPage(from: page, to: 1)
        } else {
            currentCard = page - 1
            if currentCard == totalCards - 1 { reachedLast = true }
        }
    }

    private func resetLoopPage(from sentinel: Int, to page: Int) {
        DispatchQueue.main.async {
            guard selectedPage == sentinel else { return }
            pageChangeOrigin = .loopCorrection
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selectedPage = page
            }
        }
    }

    private func advanceCard() {
        let nextPage = currentCard == totalCards - 1
            ? totalCards + 1
            : currentCard + 2
        pageChangeOrigin = .automatic
        withAnimation {
            selectedPage = nextPage
        }
    }

    private var manualPagingGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { _ in
                guard !isManualDragInProgress else { return }
                isManualDragInProgress = true
                pauseAutoplayForManualInteraction()
            }
            .onEnded { _ in
                isManualDragInProgress = false
            }
    }

    private func pauseAutoplayForManualInteraction() {
        autoplayEnabled = false
        manualInteractionGeneration += 1
    }

    @ViewBuilder
    private func card(idx: Int) -> some View {
        VStack(spacing: 0) {
            Image(icons[idx])
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
            Text(titles[idx])
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.vertical, 20)
            Text(bodies[idx])
                .font(.system(size: 12))
                .foregroundColor(.white)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    private func handleNext() {
        // v24 B2：reachedLast sticky 后（用户已看完 loop 至少一轮），任何 Next 都退出
        // 对齐 H5 L60-64（loop=true 时防止循环卡死无法退出）
        if reachedLast || currentCard >= totalCards - 1 {
            reachedLast = true
            onFinish()
            withAnimation { isPresented = false }
        } else {
            withAnimation { selectedPage = currentCard + 2 }
        }
    }
}
