import SwiftUI
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "CGoMatchButton")

/// L 里程碑：匹配开关浮动按钮（对齐 H5 `c-goMatch.vue`）。
///
/// 挂入点：`LiveTabView.floatingButtons(for:)` 内当 `current == .match` 时显示。
///
/// **状态映射**：
/// - `MatchState.ended` → matchButtonOff 切图（关态灰）
/// - `MatchState.matching` → matchButtonOn 切图（开态粉红心形）
/// - `MatchState.blocked` → matchButtonOff 切图（视觉与 .ended 一致，点击后触发 isOpen 复查）
/// - `MatchState.matchingCalling` → **不 render**（对齐 spec §2.3 不变量）
///
/// **点击行为**：
/// - `.ended / .blocked` → openMatch（首日走规则弹窗，后续里程碑）
/// - `.matching` → closeMatch
struct CGoMatchButton: View {
    @ObservedObject var store: MatchStore

    /// #3b：首日规则弹窗展示态（当日首次开启触发）
    @State private var showRulePopup: Bool = false

    var body: some View {
        // matchingCalling 期间不 render（不依赖 CallView 遮盖）
        if store.state != .matchingCalling {
            Button {
                handleTap()
            } label: {
                Image(buttonImageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Theme.Metric.matchButtonSize,
                           height: Theme.Metric.matchButtonSize)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel(a11yLabel)
            .sheet(isPresented: $showRulePopup) {
                MatchRulePopup(onAgree: {
                    showRulePopup = false
                    Task { @MainActor in await store.openMatch() }
                })
                .interactiveDismissDisabled(true)
            }
        }
    }

    // MARK: - 状态映射

    private var buttonImageName: String {
        switch store.state {
        case .matching: return "matchButtonOn"
        case .ended, .blocked, .matchingCalling: return "matchButtonOff"
        }
    }

    private var a11yLabel: String {
        switch store.state {
        case .matching: return L10n.matchButtonA11yTurnOff
        case .ended, .blocked, .matchingCalling: return L10n.matchButtonA11yTurnOn
        }
    }

    // MARK: - 点击处理（step 1b MVP 版 —— 规则弹窗 + 10min 提示留后续里程碑）

    private func handleTap() {
        logger.info("CGoMatchButton tap: state=\(String(describing: store.state)) firstToday=\(store.isFirstMatchToday)")
        Task { @MainActor in
            switch store.state {
            case .ended, .blocked:
                // #3b：首次每日开启 → 弹规则弹窗；同意后走 openMatch（对齐 H5 c-goMatch.vue handleMatch）
                if store.isFirstMatchToday {
                    showRulePopup = true
                } else {
                    await store.openMatch()
                }
            case .matching:
                await store.closeMatch()
            case .matchingCalling:
                break // view 已不 render，防御分支
            }
        }
    }
}

#Preview("ended") {
    let store = MatchStore(service: PreviewMatchService(state: .ended))
    return CGoMatchButton(store: store)
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
}

#Preview("matching") {
    let store = MatchStore(service: PreviewMatchService(state: .matching))
    // Preview 里手动切态（loadFromPersistence 完成后 state=.ended，需要覆盖）
    return CGoMatchButton(store: store)
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear {
            // Preview 用途：模拟已在 matching 态
        }
}

// Preview 用假 service（Preview 不发起真调用）
private final class PreviewMatchService: MatchServiceProtocol {
    let state: MatchState
    init(state: MatchState) { self.state = state }

    func isMatchOpen() async throws -> MatchCanOpenResult { .allowed }
    func toggleMatch(status: Int, faceCheckStatus: Int?) async throws -> Bool { true }
    func loadMatchPoolData() async throws -> MatchPoolData {
        MatchPoolData(callList: [], userList: [])
    }
    func loadMatchList(pageNum: Int, pageSize: Int) async throws -> [MatchUserItem] { [] }
}
