import SwiftUI

/// 60s 冷却态弹窗（对齐 H5 cooldownToast.vue 102 行 · 非自清 toast · 模态弹窗）
///
/// **触发时机**（对齐 H5 g-agora-party.vue :695-706）：
/// 仅房主/管理员点 footer PK 入口 + `isCoolingDown=true` 时弹出；非结算/观众端自动弹
///
/// **视觉结构**（对齐 docs/upload/party房pk冷却弹窗.png）：
/// - 紫底 22 圆角卡（`linear-gradient(300deg, #17175A → #1D0E4C → #130A2A)`）
/// - 右上角 X 关闭
/// - 中央 96×96 圆环 + 内嵌大字倒计时（紫红渐变文字）
/// - 描述文案 "PK cooldown in progress..."
/// - 底部 "View Previous Settlement" 紫红渐变长按钮 → 关闭 toast + 弹上一场结算
///
/// **交互流**：
/// - X → dismiss（父级 state.showBattleCooldownToast = false）
/// - Review → dismiss + `store.showSettlement = true`（重看上一场结算 popup）
struct PartyBattleCooldownToast: View {
    @ObservedObject var store: PartyBattleStore
    @Binding var isPresented: Bool
    /// 回调：用户点 "View Previous Settlement" 时触发 store.showSettlement=true
    var onReviewLast: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            ringCountdown.padding(.top, 8)
            descText.padding(.vertical, 20)
            reviewButton
        }
        .padding(.horizontal, 20).padding(.vertical, 30)
        .frame(width: 320)
        .background(bgGradient)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.7))
        .presentationDetents([.height(360)])
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack {
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.trailing, -10).padding(.top, -20)  // 拉到 card 右上角
    }

    /// 96×96 圆环 + 内嵌紫红渐变大字倒计时
    @ViewBuilder
    private var ringCountdown: some View {
        ZStack {
            // 双圆环装饰（H5 用 pk-wait-countdown.webp asset · iOS 用双 Circle stroke 占位）
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [Color(red: 0.52, green: 0.08, blue: 1.0), Color(red: 0.89, green: 0.00, blue: 0.20)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 3
                )
                .frame(width: 96, height: 96)
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                .frame(width: 84, height: 84)

            // 倒计时大字（H5 紫红渐变 fill · iOS 用 foregroundStyle LinearGradient）
            // max(0) 兜底防负值展示（后端 SELECTING/RUNNING 返 -1 场景 · 对齐 H5 audienceHud.vue :62 `Math.max(0, leftSec)`）
            Text("\(max(0, store.cooldownLeftSec))s")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 0.52, green: 0.08, blue: 1.0), Color(red: 0.89, green: 0.00, blue: 0.20)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .environment(\.layoutDirection, .leftToRight)  // dir="ltr" 防 RTL 反转
        }
    }

    @ViewBuilder
    private var descText: some View {
        Text("PK cooldown is in progress. Please wait a moment before starting a new PK.")
            .font(.system(size: 15))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var reviewButton: some View {
        Button {
            isPresented = false
            onReviewLast?()
        } label: {
            Text("View Previous Settlement")
                .font(.system(size: 15).bold())
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(pillGradient)
                .clipShape(Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var bgGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.09, green: 0.09, blue: 0.35),   // #17175A
                Color(red: 0.11, green: 0.06, blue: 0.30),   // #1D0E4C
                Color(red: 0.07, green: 0.04, blue: 0.16),   // #130A2A
            ],
            startPoint: .topTrailing, endPoint: .bottomLeading
        )
    }

    private var pillGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.52, green: 0.08, blue: 1.0), Color(red: 0.89, green: 0.00, blue: 0.20)],
            startPoint: .leading, endPoint: .trailing
        )
    }
}
