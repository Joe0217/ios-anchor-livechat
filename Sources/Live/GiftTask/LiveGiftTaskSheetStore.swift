import Foundation

/// Sheet 外壳 store —— 管理 activeTab 与 showRule 两个 UI 状态(spec §1.1)。
///
/// **触发**:
/// - Sheet onPresent(view onAppear):强制 `activeTab = .liveGift`(对齐 H5 girlWeeklyTask.onPopupOpen)
///   + 通知外部 historyStore.refreshAsync 拉 Tab1 首次数据
/// - 用户切 tab:`switchTab(_:)`;Tab2 首次进入触发 tycoonStore.loadAsync(外部由 view onChange 挂)
/// - 用户点右上问号:`showRule = true`
/// - 用户点 OK / VoiceOver escape:`showRule = false`
///
/// **无副作用**:纯 UI 状态,不持数据源;
/// 外部 HistoryStore / TycoonStore 生命周期与本 store 一致(同 sheet 内 @StateObject)。
@MainActor
final class LiveGiftTaskSheetStore: ObservableObject {

    enum Tab: String, CaseIterable, Equatable {
        case liveGift
        case activeTycoon
    }

    @Published var activeTab: Tab = .liveGift
    @Published var showRule: Bool = false

    init() {}

    /// Sheet 首次 present 时强制重置 —— 对齐 H5 girlWeeklyTask.onPopupOpen(L53-61):
    /// activeTab 恒重置为 liveGift + 触发 Tab1 refresh。
    ///
    /// **注意**:H5 comment 明说"不能靠子组件的 active watch 触发",
    /// 必须外壳主动 refresh。iOS 由 view 层 onAppear 显式调此方法。
    func onPresent() {
        activeTab = .liveGift
    }

    /// 用户切 tab；Tab2 的每次激活请求由 view 层 onChange 挂载。
    func switchTab(_ tab: Tab) {
        guard tab != activeTab else { return }
        activeTab = tab
    }

    /// Sheet dismiss / 离房时调
    func reset() {
        activeTab = .liveGift
        showRule = false
    }
}
