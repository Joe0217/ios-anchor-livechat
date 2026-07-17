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
            // 乐观 init canCall=true：Match tab 首帧可见（大多数正常用户 UX 无 loading 断层）。
            // 视觉级 tap 绕过由 `tapOuter` 内部的 canCall snapshot guard 挡住（见下方），功能级
            // 绕过由 CGoMatchButton UI gate + MatchStore.openMatch Store guard + RTM auto-reject 三层挡。
            //
            // 黑名单用户（101/104/105 canCall=false）冷启动 permission drain 前 tab bar 会显示 4 个
            // icon，drain 后（几十毫秒到几百毫秒）收敛为 3 个 icon —— tab icon 视觉 flicker 是
            // acceptable trade-off vs pessimistic false 导致的 tests 大改 + 正常用户 loading 断层。
            //
            // 配套 LiveTabView.reapplyTier 单 gate `permission.isLoaded`（不 gate hasLoadedTier），
            // permission drain 后立即 apply；tier 未 loaded 用 fallback `isSLevel: true`。
            applyTier(isSLevel: isS, canCall: true)
        }
    }

    // MARK: - Actions

    /// 段位信息到达 (View 层 .onChange(anchorInfoStore.info/mine) 触发)。
    /// - 首次：派生 order + 选 `availableOrder.first`
    /// - 重复 (段位刷新)：若用户已交互过保留 `userSelected`；否则保持 first
    ///
    /// P 项目权限管理 v2：canCall=false 时从可选列表移除 `.match`（避免"进空 hero 页"）。
    /// 若 userSelected == .match 时 canCall 变 false，userSelected 保持但 order 不含 → fallback 到 order.first。
    ///
    /// **code-review Finding 1/2 修复**：canCall 必填无 default 值，编译强制 caller 显式传，防止 fail-open。
    func applyTier(isSLevel: Bool, canCall: Bool) {
        var order: [HomeTopTab] = isSLevel
            ? [.live, .list, .match, .circle]
            : [.list, .match, .live, .circle]
        if !canCall {
            order.removeAll { $0 == .match }
        }
        availableOrder = order

        if let sel = userSelected, order.contains(sel) {
            // 用户曾选 → 保留业务语义 (不动)
            currentOuter = sel
        } else {
            currentOuter = order.first
        }
    }

    /// 点击外层 tab (spec §3.1 TapOuter)。
    /// **视觉级 gate 由 View 层做**（LiveTopBar tap closure 判 canCall），HomeTopTabStore 保持
    /// pure（白名单可测，不引用 SelfPermissionBridge.shared 因 +Shared.swift 不入白名单）。
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
