import Foundation

/// Home 外层 4 tab 状态机 (A-spec §3.1)。
///
/// 关键设计：
/// - `availableOrder == nil` 表示**段位未加载完**，View 层渲染 tab bar loading 占位 (spec §5.12)
/// - 段位到达通过 `applyTier(isSLevel:)` 注入；不直接订阅 `AnchorInfoStore`，便于单测
/// - 用户主动选过的 tab 通过 `userSelected` 持久化，段位刷新时保留**业务语义**而非 index 语义
@MainActor
final class HomeTopTabStore: ObservableObject {

    /// 派生的可用 tab 顺序。
    /// - `nil` = 段位未加载完，UI 展示 loading
    /// - `[Live, List, Match, Circle]` = S/SS 级
    /// - `[List, Match, Live, Circle]` = 非 S 级
    @Published private(set) var availableOrder: [HomeTopTab]?

    /// 当前选中 tab；段位未就绪前 nil。
    @Published private(set) var currentOuter: HomeTopTab?

    /// 用户主动选过的 tab — 段位变化时保留业务语义 (spec §3.1)。
    /// nil 表示用户尚未交互过，段位到达后默认选 `availableOrder.first`。
    private var userSelected: HomeTopTab?

    init(initialIsSLevel: Bool? = nil) {
        if let isS = initialIsSLevel {
            applyTier(isSLevel: isS)
        }
    }

    // MARK: - Actions

    /// 段位信息到达 (View 层 .onChange(anchorInfoStore.info/mine) 触发)。
    /// - 首次：派生 order + 选 `availableOrder.first`
    /// - 重复 (段位刷新)：若用户已交互过保留 `userSelected`；否则保持 first
    func applyTier(isSLevel: Bool) {
        let order: [HomeTopTab] = isSLevel
            ? [.live, .list, .match, .circle]
            : [.list, .match, .live, .circle]
        availableOrder = order

        if let sel = userSelected, order.contains(sel) {
            // 用户曾选 → 保留业务语义 (不动)
            currentOuter = sel
        } else {
            currentOuter = order.first
        }
    }

    /// 点击外层 tab (spec §3.1 TapOuter)。
    func tapOuter(_ tab: HomeTopTab) {
        guard let order = availableOrder, order.contains(tab) else { return }
        currentOuter = tab
        userSelected = tab
    }

    /// 横滑切到 index (spec §3.1 SwipeOuter)。
    /// TabView(.page) 用 selection: HomeTopTab Binding 而非 index，
    /// 该方法主要供单测断言；生产 View 层用 tapOuter 即可。
    func swipeOuter(toIndex idx: Int) {
        guard let order = availableOrder, order.indices.contains(idx) else { return }
        let tab = order[idx]
        currentOuter = tab
        userSelected = tab
    }
}
