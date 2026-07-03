import Foundation

/// Circle 内 3 子 tab 状态机 (A-spec §3.2)。
///
/// 纯状态机，不持有 `MomentFeedStore`：
/// - 切换无副作用 (不预拉数据；进入 Moment 才触发 enterMoment)
/// - 与 MomentFeedStore 的联动 (切走 cancel / 切入 enterMoment) 由容器 View 层
///   `.onChange(of: circleStore.currentSub)` 完成，避免 Store 间互相持有
@MainActor
final class CircleStore: ObservableObject {

    /// 初始选 `.official` 对齐 H5 `circle/index.vue:25 tabActive='official'`
    ///
    /// 注：不用 `private(set)` 是为了让 SwiftUI `TabView(selection: $store.currentSub)` 可直接绑。
    /// 业务侧仍走 `select(_:)` / `swipeSub(toIndex:)` 走单测。
    @Published var currentSub: CircleSubTab = .official

    init(initial: CircleSubTab = .official) {
        self.currentSub = initial
    }

    /// 点击 / 横滑触发的切换 (TapSub / SwipeSub 都走这里)。
    func select(_ sub: CircleSubTab) {
        currentSub = sub
    }

    /// 按 index 切换 (供单测断言 SwipeSub 的 index → enum 映射)。
    func swipeSub(toIndex idx: Int) {
        let all = CircleSubTab.allCases
        guard all.indices.contains(idx) else { return }
        currentSub = all[idx]
    }
}
