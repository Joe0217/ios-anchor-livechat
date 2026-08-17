import SwiftUI

/// 所有人可查看的转盘状态与操作面板。动画由服务端阶段广播推进；客户端不自行抽取结果。
///
/// 视觉对齐 H5 `super-wheel-panel.vue`：
/// - 遮罩 rgba(0,0,0,0.5)、内容 max-width 340pt 居中
/// - close/zoom/大倒计时/help 全部相对 340pt 容器（不是全屏）定位
/// - 大号倒计时 50pt 斜体渐变 `#E3FBB5→#8AFC00` + 深绿 1pt 描边 + 1s 心跳
/// - 标题切图 239×60pt，转盘 302×297pt 上溢 26pt 贴近标题
/// - 提示区固定 h-105：'人数不足'占位 / 加注区（Winning Ratio 温度条 + +50/+500 双档 + Add bets/hand）
///   / Join 与 Joined 复用 btn-join 切图 / Spectating 观战文本
struct PartySuperWheelPanel: View {
    @ObservedObject var wheelStore: PartySuperWheelStore
    let isRoomOwner: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var reportedFinalRoundID: String?
    @State private var showsRules = false
    @State private var pulseCountdown = false
    @State private var fingerBounce = false

    private let panelMaxWidth: CGFloat = 340
    private let closeIconSize: CGFloat = 24
    private let helpIconSize: CGFloat = 28
    private let bigCountdownFont: CGFloat = 50
    private let titleWidth: CGFloat = 239
    private let titleHeight: CGFloat = 60
    private let dialWidth: CGFloat = 302
    private let dialHeight: CGFloat = 297
    private let dialOverlapUp: CGFloat = 26
    private let actionAreaHeight: CGFloat = 105
    private let actionBarHeight: CGFloat = 67
    private let betButtonWidth: CGFloat = 118
    private let joinButtonWidth: CGFloat = 179

    var body: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            containerColumn
        }
        .overlay {
            if wheelStore.shouldPresentResult {
                PartySuperWheelResultOverlay(wheelStore: wheelStore, isRoomOwner: isRoomOwner)
            }
        }
        .overlay {
            if showsRules {
                PartySuperWheelRulesOverlay { showsRules = false }
            }
        }
        .task(id: finalResultTrackingKey, priority: .userInitiated) {
            reportFinalResultIfNeeded()
        }
        .onAppear(perform: handleAppear)
    }

    /// 340pt 宽的居中列，zoom/大倒计时都作为它的 overlay（相对容器坐标，不是全屏）
    /// 左上关闭按钮已按需求隐藏 —— 房主关闭对局功能移到其他入口。
    private var containerColumn: some View {
        centerColumn
            .frame(maxWidth: panelMaxWidth)
            .overlay(alignment: .topTrailing) { topTrailingButton }
            .overlay(alignment: .top) { topCountdownOverlay }
    }

    private var topTrailingButton: some View {
        // SUPER WINNER 标题右侧按钮(zoom/minimize)= Group 109607
        topIconButton(asset: "superWinnerHeaderBtnLeft", action: onMinimize)
            .padding(.trailing, 16)
            .padding(.top, 50)
            .opacity(wheelStore.shouldPresentResult ? 0 : 1)
            .allowsHitTesting(!wheelStore.shouldPresentResult)
    }

    @ViewBuilder
    private var topCountdownOverlay: some View {
        if wheelStore.hasBigCountdown {
            bigCountdown
                .padding(.top, 34)
                .allowsHitTesting(false)
        }
    }

    private var centerColumn: some View {
        VStack(spacing: 0) {
            // 标题 mb-2 mt-8 → 上 8 下 2
            titleImage
                .padding(.top, 8)
                .padding(.bottom, 2)
            // 转盘 -mt-26 上溢，用 offset 让其视觉上移（不用 negative padding，SwiftUI 表现不稳定）
            dial
                .offset(y: -dialOverlapUp)
                .padding(.bottom, -dialOverlapUp)
            // 提示 + 按钮固定占位区
            actionArea
                .frame(height: actionAreaHeight)
                .padding(.top, 6)
        }
    }

    private func topIconButton(asset: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CDNAssetImage(asset)
                .resizable()
                .scaledToFit()
                .frame(width: closeIconSize, height: closeIconSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    // MARK: - Big countdown

    private var bigCountdown: some View {
        VStack(spacing: 4) {
            countdownNumber
            if wheelStore.wheelState?.state == 4 {
                Text(L10n.PartyRoom.superWheelGetReady)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: 0xFFE9A6))
            }
        }
        .allowsHitTesting(false)
    }

    private var countdownNumber: some View {
        let text = String(wheelStore.remainingSeconds)
        let font = Font.system(size: bigCountdownFont, weight: .heavy, design: .rounded).italic()
        let strokeColor = Color(hex: 0x002E0C)
        let gradient = LinearGradient(
            colors: [Color(hex: 0xE3FBB5), Color(hex: 0x8AFC00)],
            startPoint: .top,
            endPoint: .bottom
        )
        return ZStack {
            countdownStroke(text: text, font: font, color: strokeColor, x: 1, y: 0)
            countdownStroke(text: text, font: font, color: strokeColor, x: -1, y: 0)
            countdownStroke(text: text, font: font, color: strokeColor, x: 0, y: 1)
            countdownStroke(text: text, font: font, color: strokeColor, x: 0, y: -1)
            Text(text)
                .font(font)
                .foregroundStyle(gradient)
                .monospacedDigit()
                .environment(\.layoutDirection, .leftToRight)
        }
        .scaleEffect(pulseCountdown ? 1.12 : 1)
        .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: pulseCountdown)
    }

    private func countdownStroke(text: String, font: Font, color: Color, x: CGFloat, y: CGFloat) -> some View {
        Text(text)
            .font(font)
            .foregroundColor(color)
            .monospacedDigit()
            .environment(\.layoutDirection, .leftToRight)
            .offset(x: x, y: y)
    }

    // MARK: - Title / Dial

    private var titleImage: some View {
        CDNAssetImage("superWinnerTitle")
            .resizable()
            .scaledToFit()
            .frame(width: titleWidth, height: titleHeight)
            .accessibilityLabel(L10n.PartyRoom.superWheelTitle)
    }

    @ViewBuilder
    private var dial: some View {
        if let state = wheelStore.wheelState {
            PartySuperWheelDial(
                state: dialInputState(for: state),
                pool: dialPool,
                spinTrigger: wheelStore.spinTriggerCounter
            )
                .overlay(alignment: .bottomLeading) {
                    helpButton.padding(.leading, 2).padding(.bottom, 6)
                }
        } else {
            Color.clear.frame(width: dialWidth, height: dialHeight)
        }
    }

    /// 终局展示结束到新局到达之间的空档喂空盘 + 奖池 0，避免残留上一局数据。
    private func dialInputState(for state: PartySuperWheelState) -> PartySuperWheelState {
        guard isResting(state) else { return state }
        var cleared = state
        cleared.participants = []
        cleared.totalPool = 0
        return cleared
    }

    private var dialPool: Int64 {
        guard let state = wheelStore.wheelState else { return 0 }
        return isResting(state) ? 0 : wheelStore.displayPool
    }

    /// 终局展示结束但未拿到下一局：state=8 且倒计时清零。
    private func isResting(_ state: PartySuperWheelState) -> Bool {
        state.state == 8 && wheelStore.remainingSeconds <= 0
    }

    private var helpButton: some View {
        Button(action: onHelp) {
            CDNAssetImage("superWinnerHelp")
                .resizable()
                .scaledToFit()
                .frame(width: helpIconSize, height: helpIconSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.PartyRoom.superWheelRulesTitle)
    }

    // MARK: - Action area

    /// h-105 提示占位区：VStack 强制布局,顶部 minPlayers 文案 + Spacer 撑开 + 底部按钮带,
    /// 保证「转盘 → 提示 → 按钮」三层视觉纵向对齐(对齐 H5 super-wheel-panel.vue 的 `top-4 + bottom-0` 布局)。
    @ViewBuilder
    private var actionArea: some View {
        VStack(spacing: 0) {
            // 人数不足提示(H5 top-4,置顶居中)
            if let state = wheelStore.wheelState, needMorePlayers(state) {
                Text(L10n.PartyRoom.superWheelMinPlayers)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
            // 按钮带 h-67(终局静止期不渲染按钮)
            if let state = wheelStore.wheelState, !isResting(state) {
                actionBar
                    .frame(height: actionBarHeight)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func needMorePlayers(_ state: PartySuperWheelState) -> Bool {
        !isResting(state) && state.participants.count < 2
    }

    @ViewBuilder
    private var actionBar: some View {
        if wheelStore.shouldShowBetArea {
            betAreaContent
        } else if wheelStore.canJoin {
            joinButton
        } else if wheelStore.isMyParticipantAlive && wheelStore.isRegistering {
            joinedButton
        } else if wheelStore.isSpectating {
            spectatingText
        } else {
            Color.clear
        }
    }

    // MARK: Bet area

    private var betAreaContent: some View {
        HStack(spacing: 10) {
            winningRatioMeter
            betButtonsRow
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var winningRatioMeter: some View {
        HStack(spacing: 6) {
            ratioBar
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.PartyRoom.superWheelWinningRatio)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(wheelStore.myWinningRatio)%")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(wheelStore.myWinningRatio >= 50
                                     ? Color(hex: 0xF5AB00)
                                     : .white)
                    .monospacedDigit()
                    .environment(\.layoutDirection, .leftToRight)
            }
            .frame(width: 62, alignment: .leading)
        }
    }

    /// 温度条：12×57 track 圆角 20 深灰底，内部 8×(57-4)*ratio Capsule 距底 2pt，颜色随 ≥50% 切换
    private var ratioBar: some View {
        let ratio = max(0, min(100, wheelStore.myWinningRatio))
        let fillHeight = CGFloat(53) * CGFloat(ratio) / 100
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(hex: 0x2E2E2E))
            Capsule()
                .fill(ratio >= 50 ? Color(hex: 0xFF0000) : Color(hex: 0xFF9D2C))
                .frame(width: 8, height: max(0, fillHeight))
                .padding(.bottom, 2)
        }
        .frame(width: 12, height: 57)
    }

    private var betButtonsRow: some View {
        HStack(spacing: 8) {
            betButton(amount: 50, asset: "superWinnerBtnBet50", isLast: false)
            betButton(amount: 500, asset: "superWinnerBtnBet500", isLast: true)
        }
        .overlay(alignment: .topTrailing) {
            if wheelStore.isBetting {
                addBetsBadge
                    .offset(x: -3, y: -34)
            }
        }
    }

    private var addBetsBadge: some View {
        HStack(spacing: -5) {
            CDNAssetImage("superWinnerAddBets")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
            Text(L10n.PartyRoom.superWheelAddBets)
                .font(.system(size: 16, weight: .heavy).italic())
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: Color(hex: 0xFF9600), location: 0),
                            .init(color: Color(hex: 0xFF6829), location: 0.55),
                            .init(color: Color(hex: 0xFF0000), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .fixedSize()
        }
        .allowsHitTesting(false)
    }

    private func betButton(amount: Int, asset: String, isLast: Bool) -> some View {
        Button(action: { Task { await handleBet(amount: amount) } }) {
            ZStack(alignment: .top) {
                CDNAssetImage(asset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: betButtonWidth, height: actionBarHeight)
                HStack(spacing: 4) {
                    Text("+\(amount)")
                        .environment(\.layoutDirection, .leftToRight)
                    CDNAssetImage("giftPanelBalanceCoin")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                }
                .font(.system(size: 16, weight: .heavy))
                .foregroundColor(.white)
                .padding(.top, 20)
            }
            .frame(width: betButtonWidth, height: actionBarHeight)
            .overlay(alignment: .bottomTrailing) {
                if isLast && !wheelStore.isBetDisabled {
                    CDNAssetImage("superWinnerHand")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 78, height: 78)
                        .offset(x: 0, y: 45 + (fingerBounce ? -4 : 0))
                        .allowsHitTesting(false)
                        .animation(
                            .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                            value: fingerBounce
                        )
                }
            }
            .grayscale(wheelStore.isBetDisabled ? 1 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(wheelStore.isBetDisabled || wheelStore.isPerformingAction)
    }

    // MARK: Join / Joined / Spectating

    private var joinButton: some View {
        Button(action: { Task { await wheelStore.join() } }) {
            ZStack(alignment: .top) {
                CDNAssetImage("superWinnerBtnJoin")
                    .resizable()
                    .scaledToFit()
                    .frame(width: joinButtonWidth, height: actionBarHeight)
                HStack(spacing: 4) {
                    Text("\(L10n.PartyRoom.superWheelJoin) · \(wheelStore.wheelState?.entryFee ?? 0)")
                        .environment(\.layoutDirection, .leftToRight)
                    CDNAssetImage("giftPanelBalanceCoin")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                }
                .font(.system(size: 16, weight: .heavy))
                .foregroundColor(.white)
                .padding(.top, 18)
            }
            .frame(width: joinButtonWidth, height: actionBarHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(wheelStore.isPerformingAction)
        .opacity(wheelStore.isPerformingAction ? 0.92 : 1)
    }

    private var joinedButton: some View {
        ZStack(alignment: .top) {
            CDNAssetImage("superWinnerBtnJoinGray")
                .resizable()
                .scaledToFit()
                .frame(width: joinButtonWidth, height: actionBarHeight)
            Text(L10n.PartyRoom.superWheelJoined)
                .font(.system(size: 16, weight: .heavy))
                .foregroundColor(.white)
                .padding(.top, 18)
        }
        .frame(width: joinButtonWidth, height: actionBarHeight)
    }

    private var spectatingText: some View {
        Text(L10n.PartyRoom.superWheelSpectating)
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.7))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func handleAppear() {
        pulseCountdown = true
        fingerBounce = true
    }

    private func handleBet(amount: Int) async {
        guard amount > 0, !wheelStore.isBetDisabled else { return }
        await wheelStore.bet(amount: amount)
    }

    private func onMinimize() {
        wheelStore.dismissPanel()
        dismiss()
    }

    private func onHelp() {
        showsRules = true
    }

    // MARK: - Analytics

    private var finalResultTrackingKey: String {
        let state = wheelStore.wheelState
        return "\(state?.roundId ?? "")-\(state?.state ?? 0)"
    }

    private func reportFinalResultIfNeeded() {
        guard let state = wheelStore.wheelState,
              state.state == 8,
              reportedFinalRoundID != state.roundId else { return }
        reportedFinalRoundID = state.roundId
        var properties = PartyAnalytics.roomProperties(roomId: state.roomId, ownerId: state.hostId)
        properties["dia"] = state.entryFee
        PartyAnalytics.track("b_wheel_result_view", properties: properties)
    }
}
