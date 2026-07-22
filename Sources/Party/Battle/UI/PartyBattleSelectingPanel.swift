import SwiftUI

/// SELECTING 期顶部状态条（对齐 H5 selectingPanel.vue "视觉与 audienceHud 一致"）
///
/// 等待开始阶段复用分数计算，但采用设计稿中的红蓝渐变状态卡：
/// 标题、规则入口、双边 PK 分数、中心标记和倒计时上下分层。
/// `leftSec` 在此阶段代表选队倒计时，RUNNING 阶段仍复用同一 HUD 的普通样式。
struct PartyBattleSelectingPanel: View {
    @ObservedObject var store: PartyBattleStore
    let onRuleTap: (() -> Void)?

    init(store: PartyBattleStore, onRuleTap: (() -> Void)? = nil) {
        self.store = store
        self.onRuleTap = onRuleTap
    }

    var body: some View {
        PartyBattleRunningHud(store: store, appearance: .selecting, onRuleTap: onRuleTap)
    }
}
