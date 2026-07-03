import Foundation

/// tabbar 锁（B-spec-开播设置页 §1.4 🔴#1 🔴#5 修）。
///
/// **动机**：`LiveSettingsView.startTapped()` 进入 `.starting` 后调 `LiveService.startLive`（三接口串行 1-3s），
/// 期间用户切 tab → `MainTabView.swift:104 if selection == .work` 销毁 NavigationStack →
/// **后端已建房 iOS 无心跳/rtc = 僵尸房间**。用 shared singleton 让 MainTabView 感知锁态，
/// tabbar `.allowsHitTesting(false)` 拦截触摸；push 完成 View 消失，Store deinit 自然 unlock。
///
/// 单例合理性：MainTabView 在 view tree 顶端、LiveSettingsView 在 stack 深处，二者无直接引用关系；
/// tabbar 锁是**跨页面共享的 UI 状态**，符合 CLAUDE.md「全局只放跨页面共享状态」。
@MainActor
final class LiveSettingsLock: ObservableObject {
    static let shared = LiveSettingsLock()

    @Published private(set) var isLocked: Bool = false

    func lock() { isLocked = true }
    func unlock() { isLocked = false }

    private init() {}
}
