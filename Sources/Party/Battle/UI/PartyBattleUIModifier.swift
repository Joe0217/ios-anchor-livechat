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
    /// 由 PartyRoomView 的权限桥接传入。关闭时整个 PK UI 只能清理，不能继续拉状态或展示残留弹层。
    let isFeatureEnabled: Bool
    let effectiveRoomId: String
    @Binding var showInitiate: Bool
    @Binding var showForceEnd: Bool
    @Binding var showCooldownToast: Bool
    @Binding var showRules: Bool
    @State private var shouldPresentSettlementAfterCooldownDismissal = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: featureBinding($showInitiate)) {
                PartyBattleInitiatePopup(store: battleStore) {
                    // 直接回写 sheet binding，确保 PK 创建成功后立即关闭发起页。
                    showInitiate = false
                }
                    .selfSizingSheetHeight(minHeight: 200, maxHeight: 700)
                    .presentationDragIndicator(.visible)
                    .partyBattleSheetBackground(.initiate)
            }
            .sheet(isPresented: featureBinding($showForceEnd)) {
                PartyBattleForceEndConfirm(store: battleStore)
                    .presentationDetents([.fraction(0.5), .fraction(0.8)])
                    .partyBattleSheetBackground(.dark)
            }
            .sheet(isPresented: featureBinding($showRules)) {
                PartyBattleRulesPopup()
                    .presentationDetents([.fraction(0.5), .fraction(0.8)])
                    .partyBattleSheetBackground(.dark)
            }
            .sheet(isPresented: featureBinding($showCooldownToast), onDismiss: presentQueuedSettlementAfterCooldownDismissal) {
                // 模态弹窗（非自清 toast）· 用户点 X 或 View Previous Settlement 关闭
                // review 回调 → 关闭本 sheet + 触发 showSettlement=true 打开结算 popup（对齐 H5 g-agora-party.vue:705）
                PartyBattleCooldownToast(
                    store: battleStore,
                    isPresented: $showCooldownToast,
                    onReviewLast: {
                        shouldPresentSettlementAfterCooldownDismissal = true
                    }
                )
                .presentationDetents([.fraction(0.5), .fraction(0.8)])
                .partyBattleSheetBackground(.dark)
            }
            // H5 `endedSettlement.vue` 使用 fixed mask 覆盖房间，而不是底部 sheet。
            .overlay {
                if isFeatureEnabled && battleStore.showSettlement {
                    PartyBattleEndedSettlement(store: battleStore) {
                        battleStore.closeSettlement()
                    }
                    .transition(.opacity)
                    .zIndex(100)
                }
            }
            .task(id: featureTaskID) { await handleAppearTask() }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                handleTick()
            }
            .onChange(of: isFeatureEnabled) { enabled in
                if !enabled {
                    disableFeature()
                }
            }
    }

    // MARK: - Tasks / handlers

    private func handleAppearTask() async {
        guard isFeatureEnabled else {
            disableFeature()
            return
        }

        // 冷启动 refresh 兜底（R-20）+ 全局开关按需拉取（首版每进房一次）
        if !effectiveRoomId.isEmpty {
            await battleStore.refreshIfNeeded(roomId: effectiveRoomId)
        }
        // `.task(id:)` 在能力撤销时会取消旧任务；在继续进行下一次请求前明确检查，
        // 避免取消后的旧 View 继续触发全局配置拉取。
        guard !Task.isCancelled, isFeatureEnabled else { return }
        await battleStore.loadGlobalConfig()
    }

    private func handleTick() {
        guard isFeatureEnabled else { return }
        guard battleStore.isSelecting || battleStore.isRunning else { return }
        battleStore.tickLeft()
    }

    private func presentQueuedSettlementAfterCooldownDismissal() {
        guard isFeatureEnabled else {
            shouldPresentSettlementAfterCooldownDismissal = false
            return
        }
        guard shouldPresentSettlementAfterCooldownDismissal else { return }
        shouldPresentSettlementAfterCooldownDismissal = false
        battleStore.showSettlementBinding.wrappedValue = true
    }

    private var featureTaskID: String {
        "\(effectiveRoomId)|\(isFeatureEnabled ? "enabled" : "disabled")"
    }

    /// 同时处理权限热切换与初次 deny-by-default。绑定本身也在 getter 处硬拒绝，
    /// 因此 SwiftUI sheet 动画尚未完成时不会重新呈现被关闭的 PK 页面。
    private func disableFeature() {
        showInitiate = false
        showForceEnd = false
        showCooldownToast = false
        showRules = false
        shouldPresentSettlementAfterCooldownDismissal = false
        battleStore.reset()
    }

    private func featureBinding(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { isFeatureEnabled && binding.wrappedValue },
            set: { binding.wrappedValue = isFeatureEnabled && $0 }
        )
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
