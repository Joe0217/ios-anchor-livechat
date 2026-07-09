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

    private var balanceView: some View {
        HStack(spacing: 4) {
            Image("giftPanelBalanceCoin")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
            Text(store.balanceValue.map { "\($0)" } ?? "--")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    // MARK: - Stepper

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

            Text("\(store.count)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(minWidth: 26)

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

    @ViewBuilder
    private var actionButton: some View {
        switch store.config.footer {
        case .none, .instantSelect:
            EmptyView()
        case .confirm(let label, _):
            primaryButton(label: label)
        case .send:
            primaryButton(label: L10n.giftPickerSend)
        case .askFor:
            primaryButton(label: L10n.callActionAskForGift)
        }
    }

    private func primaryButton(label: String) -> some View {
        let enabled = store.canTriggerAction
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
                Capsule().fill(enabled ? Color.pink : Color.white.opacity(0.15))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
