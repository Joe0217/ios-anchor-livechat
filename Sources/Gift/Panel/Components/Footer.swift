import SwiftUI

/// 面板底部动作条（spec §3 UI 结构底部区）—— 余额 · count stepper · 主按钮。
///
/// 仅在 `footer=.confirm/.send/.askFor` 时渲染；`.none/.instantSelect` 由 Panel 层判定不挂载。
///
/// 布局对齐设计稿 `送礼弹窗-背包礼物.png` / `送礼弹窗-背包礼物2.png`：
/// - balance visible → 左侧余额胶囊
/// - stepper visible → 中间数量步进器
/// - 右侧主按钮（label 由 footer mode 决定）
struct GiftPanelFooter: View {
    @ObservedObject var store: CommonGiftPanelStore

    var body: some View {
        HStack(spacing: 10) {
            if store.config.balance.isVisible {
                balanceView
            }

            Spacer(minLength: 0)

            if let range = store.config.countStepper.range {
                stepperView(range: range)
            }

            actionButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Balance

    /// balance 胶囊 tap = **刷新余额**（主播端无充值功能；对齐 H5 用户端 tap 打开充值弹窗
    /// 的位置，语义调整为主播端专用"重拉一次余额"）。
    /// 场景兼容：仅当 config 有 balance source 时可点（`.hidden` 场景 balanceView 本身不渲染）
    /// 其他场景（callGate/wishGift/liveDisplayOnly/imBind/callAskFor）balance 默认 hidden，
    /// 无需额外分支。
    /// refreshBalance 进行中：胶囊右侧显示 ProgressView 提示"刷新中"（isRefreshingBalance @Published 驱动）
    private var balanceView: some View {
        Button(action: {
            Task { await store.refreshBalance() }
        }) {
            HStack(spacing: 4) {
                Image("giftPanelBalanceCoin")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                Text(store.balanceValue.map { "\($0)" } ?? "--")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                if store.isRefreshingBalance {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white.opacity(0.85))
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy || store.isRefreshingBalance)
    }

    // MARK: - Stepper

    /// PA-3（对齐 H5 party-gift-popup.vue L1095-1104 sendGiftConfig 快选）：
    /// 数字 tap 弹 Menu 6 档快选（99/50/20/10/5/1）；range 内的档位才可见。
    /// 硬编默认值对齐 H5 partyGiftConfig.sendGiftConfig 默认 [1,5,10,20,50,99]。
    private static let quickCountValues: [Int] = [99, 50, 20, 10, 5, 1]

    private func stepperView(range: ClosedRange<Int>) -> some View {
        let canDec = store.count > range.lowerBound && !store.isBusy
        let canInc = store.count < range.upperBound && !store.isBusy
        return HStack(spacing: 8) {
            Button(action: { store.decrementCount() }) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(canDec ? .white : .white.opacity(0.3))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canDec)

            Menu {
                ForEach(Self.quickCountValues, id: \.self) { n in
                    // 只列 range 内的值，超范围的档位隐藏
                    if range.contains(n) {
                        Button("\(n)") { store.setCount(n) }
                    }
                }
            } label: {
                Text("\(store.count)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(minWidth: 26)
                    .contentShape(Rectangle())
            }
            .disabled(store.isBusy)

            Button(action: { store.incrementCount() }) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(canInc ? .white : .white.opacity(0.3))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canInc)
        }
    }

    // MARK: - Action button

    /// **H-5 phase 感知 label**（spec F10/F11）：
    /// - phase = .insufficientBalance → "Recharge"（可点，走 store.triggerAction → onRechargeRequested）
    /// - phase = .sendFailed → "Retry"（可点，走 store.triggerAction 重发同 payload）
    /// - phase = .sending → 转圈 label 空
    /// - 其他 → 按 footer 类型默认 label
    @ViewBuilder
    private var actionButton: some View {
        switch store.config.footer {
        case .none, .instantSelect:
            EmptyView()
        case .confirm(let label, _):
            primaryButton(label: phaseAwareLabel(default: label))
        case .send:
            primaryButton(label: phaseAwareLabel(default: L10n.giftPickerSend))
        case .askFor:
            primaryButton(label: phaseAwareLabel(default: L10n.callActionAskForGift))
        }
    }

    private func phaseAwareLabel(default defaultLabel: String) -> String {
        switch store.phase {
        case .insufficientBalance: return L10n.giftPickerRecharge
        case .sendFailed: return L10n.giftPickerRetry
        default: return defaultLabel
        }
    }

    /// **H-5 phase 感知 enabled**：
    /// - phase = .insufficientBalance → true（tap → recharge 分流；balance 校验不阻塞）
    /// - phase = .sendFailed → 走 canTriggerAction 常规判定（isBusy=false + 保留 selection → 允许 retry）
    /// - 其他 → canTriggerAction
    private var isActionEnabled: Bool {
        if store.phase == .insufficientBalance { return true }
        return store.canTriggerAction
    }

    private func primaryButton(label: String) -> some View {
        let enabled = isActionEnabled
        return Button(action: { store.triggerAction() }) {
            ZStack {
                if store.phase == .sending {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Text(label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .frame(minWidth: 88, minHeight: 36)
            .padding(.horizontal, 20)
            .background(
                // 主题按钮色：Theme.Palette.brandPink（"通用深粉 / B 级" 品牌主粉，
                // 单一来源；未来改主题只需 Theme.swift 内改一处）
                Capsule().fill(enabled ? Theme.Palette.brandPink : Color.white.opacity(0.15))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
