import SwiftUI

/// 首次开播规则阅读页（严格对齐 H5 `views/liveRule/component/firstLiveRule.vue`）。
///
/// 触发路径：Work → tap Go Live → 若 `FirstLiveTracker.isFirstLive == true` → 本页 →
/// 10s 倒计时结束 Confirm 按钮激活 → tap Confirm → path 替换到 LiveSettings（清 firstLiveRule 栈避免 back 回本页）
///
/// 严格照 H5 布局：
/// - 顶部："Before You Start Firstly" title + 长段介绍
/// - "Live Streaming Guidelines" title + 7 条规则（title + content）
/// - 底部 fixed Confirm 按钮：倒计时中 disabled 显示 "Confirm (N)"；到 0 后可点显示 "Confirm"
///
/// 倒计时到 0 时（不是点 Confirm 时）置 `isFirstLive = false`——即使用户 back 也不再弹（H5 语义）
struct FirstLiveRuleView: View {
    @Binding var path: NavigationPath

    @State private var countDown = 10
    @State private var isClickable = false
    @State private var timerTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Theme.Palette.screenBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Section 1: Before You Start Firstly
                    Text(L10n.firstLiveRuleBeforeStartTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(L10n.firstLiveRuleBeforeStartDesc)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)

                    // Section 2: Live Streaming Guidelines 7 条
                    Text(L10n.firstLiveRuleGuidelinesTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.top, 12)

                    ForEach(1...7, id: \.self) { idx in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.firstLiveRuleGuidelineTitle(idx))
                                .font(.system(size: 15))
                                .foregroundStyle(.white)
                            Text(L10n.firstLiveRuleGuidelineContent(idx))
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 15)
                .padding(.top, 15)
                .padding(.bottom, 80)   // 让位给底部 Confirm 按钮
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { confirmBar }
        .navigationTitle(L10n.firstLiveRuleNavTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await startCountdown() }
        .onDisappear { timerTask?.cancel() }
        .preferredColorScheme(.dark)
    }

    // MARK: - 底部 Confirm bar（对齐 H5 fixed bottom + safe-area）

    private var confirmBar: some View {
        HStack {
            Button {
                guard isClickable else { return }
                // 用 path 替换语义：清空后 append LiveSettings，避免 back 回本规则页
                // 对齐 H5 router.push('/liveSetting')（进入设置页后 back 应回 Work 根，非本规则页）
                path = NavigationPath()
                path.append(WorkRoute.liveSettings)
            } label: {
                Text(buttonText)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        isClickable
                            ? AnyShapeStyle(LinearGradient(
                                colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                                startPoint: .leading, endPoint: .trailing))
                            : AnyShapeStyle(Color(hex: 0x2B213E))   // H5 unClickable = #2B213E
                    )
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!isClickable)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.8))
    }

    /// 按钮文案（对齐 H5 firstLiveRule.vue:32-34）
    private var buttonText: String {
        countDown > 0
            ? "\(L10n.firstLiveRuleConfirm) (\(countDown))"
            : L10n.firstLiveRuleConfirm
    }

    // MARK: - Countdown

    /// 10 秒倒计时。到 0 时置 isFirstLive=false（对齐 H5 firstLiveRule.vue:24 —— 不是点 Confirm 时置，
    /// 而是倒计时结束就置；即使用户 back 也不再弹）
    private func startCountdown() async {
        timerTask?.cancel()
        timerTask = Task {
            while countDown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    countDown -= 1
                    if countDown <= 0 {
                        FirstLiveTracker.markConsumed()
                        isClickable = true
                    }
                }
            }
        }
    }
}
