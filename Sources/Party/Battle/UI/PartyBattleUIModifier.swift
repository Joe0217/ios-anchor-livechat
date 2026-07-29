import SwiftUI

/// F-1a Task 22：PartyBattle UI 集中挂载 modifier（对齐 spec §6.2）
///
/// 挂到 PartyRoomView 的 sceneBody，一次性接入所有 battle overlay/sheet。
/// 独立文件 + 独立结构体避免 sceneBody 复杂度膨胀（[swiftui-body-type-check-timeout] rule）。
///
/// **F-1a 挂载职责**：
/// - 战队 HUD、选队/Top3 条由 `PartyRoomView.pkBattleArea` 置于战队盒上下
/// - 3 sheet：InitiatePopup / ForceEndConfirm / RulesPopup；结算使用房间内 overlay popup
/// - `.task`：进房时 refresh state + 拉全局开关
/// - `.onReceive Timer.publish`：每秒 tickLeft 递减 leftSec（SELECTING/RUNNING 期）
struct PartyBattleUIModifier: ViewModifier {
    @ObservedObject var battleStore: PartyBattleStore
    let effectiveRoomId: String
    @Binding var showInitiate: Bool
    @Binding var showForceEnd: Bool
    @Binding var showCooldownToast: Bool
    @Binding var showRules: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showInitiate) {
                PartyBattleInitiatePopup(store: battleStore) {
                    // 直接回写 sheet binding，确保 PK 创建成功后立即关闭发起页。
                    showInitiate = false
                }
                    .selfSizingSheetHeight(minHeight: 200, maxHeight: 700)
                    .presentationDragIndicator(.visible)
                    .partyBattleSheetBackground(.initiate)
            }
            .sheet(isPresented: $showForceEnd) {
                PartyBattleForceEndConfirm(store: battleStore)
                    .presentationDetents([.fraction(0.5), .fraction(0.8)])
                    .partyBattleSheetBackground(.dark)
            }
            .sheet(isPresented: $showRules) {
                PartyBattleRulesPopup()
                    .presentationDetents([.fraction(0.5), .fraction(0.8)])
                    .partyBattleSheetBackground(.dark)
            }
            .sheet(isPresented: $showCooldownToast) {
                // 模态弹窗（非自清 toast）· 用户点 X 或 View Previous Settlement 关闭
                // review 回调 → 关闭本 sheet + 触发 showSettlement=true 打开结算 popup（对齐 H5 g-agora-party.vue:705）
                PartyBattleCooldownToast(
                    store: battleStore,
                    isPresented: $showCooldownToast,
                    onReviewLast: {
                        // dismiss 完成后再 flip showSettlement · 避免同一 tick 与 cooldown sheet 冲突
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms 让 dismiss 完成
                            battleStore.showSettlementBinding.wrappedValue = true
                        }
                    }
                )
                .presentationDetents([.fraction(0.5), .fraction(0.8)])
                .partyBattleSheetBackground(.dark)
            }
            // H5 `endedSettlement.vue` 使用 fixed mask 覆盖房间，而不是底部 sheet。
            .overlay {
                if battleStore.showSettlement {
                    PartyBattleEndedSettlement(store: battleStore) {
                        battleStore.closeSettlement()
                    }
                    .transition(.opacity)
                    .zIndex(100)
                }
            }
            .task(id: effectiveRoomId) { await handleAppearTask() }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                handleTick()
            }
    }

    // MARK: - Tasks / handlers

    private func handleAppearTask() async {
        // 冷启动 refresh 兜底（R-20）+ 全局开关按需拉取（首版每进房一次）
        if !effectiveRoomId.isEmpty {
            await battleStore.refreshIfNeeded(roomId: effectiveRoomId)
        }
        await battleStore.loadGlobalConfig()
    }

    private func handleTick() {
        guard battleStore.isSelecting || battleStore.isRunning else { return }
        battleStore.tickLeft()
    }
}

/// 让 PK sheet 高度随实际内容变化，避免发起态和强制结束态出现固定高度留白。
private struct PartyBattleSheetContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PartyBattleContentDetentModifier: ViewModifier {
    @State private var detent: PresentationDetent = .medium

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PartyBattleSheetContentHeightKey.self,
                        value: proxy.size.height
                    )
                }
            }
            .onPreferenceChange(PartyBattleSheetContentHeightKey.self) { height in
                guard height > 0 else { return }
                let contentDetent = PresentationDetent.height(ceil(height))
                if detent != contentDetent {
                    detent = contentDetent
                }
            }
            .presentationDetents([detent])
            .presentationDragIndicator(.visible)
    }
}

private extension View {
    func partyBattleContentDetent() -> some View {
        modifier(PartyBattleContentDetentModifier())
    }
}

private enum PartyBattleSheetBackgroundStyle {
    case initiate
    case dark

    var gradient: LinearGradient {
        switch self {
        case .initiate:
            return LinearGradient(
                colors: [Color(red: 0.22, green: 0.12, blue: 0.62), Color(red: 0.09, green: 0.02, blue: 0.24)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .dark:
            return LinearGradient(
                colors: [Color(red: 0.09, green: 0.09, blue: 0.35), Color(red: 0.11, green: 0.06, blue: 0.30), Color(red: 0.07, green: 0.04, blue: 0.16)],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )
        }
    }
}

private extension View {
    @ViewBuilder
    func partyBattleSheetBackground(_ style: PartyBattleSheetBackgroundStyle) -> some View {
        if #available(iOS 16.4, *) {
            self.presentationBackground {
                style.gradient.ignoresSafeArea()
            }
        } else {
            self.background {
                style.gradient.ignoresSafeArea()
            }
        }
    }
}
