import Foundation
import Combine

/// Home 外层 4 tab 的跨模块导航请求总线。
///
/// **动机**：`HomeTopTabStore` 是 `LiveTabView` 局部 `@StateObject`，外部（如 Work `ToolsSection`）
/// 无法直接改。Work Match 图标点击时希望切到 Home + Match top tab —— 用一个 shared 消息总线：
/// - Work 侧：`HomeNavigationBus.shared.requestTopTab(.match)` + `MainTabView` env action 切 `.home`
/// - LiveTabView 侧：`.onChange(of: navBus.pendingTopTab)` → `homeStore.tapOuter(tab)` + `pendingTopTab = nil`
///
/// 用总线而非 hoisting `HomeTopTabStore` 到 MainTabView：避免波及 keep-alive 语义 + Preview + 单测。
@MainActor
final class HomeNavigationBus: ObservableObject {
    static let shared = HomeNavigationBus()

    /// 待处理的 top tab 切换请求。LiveTabView 观察此字段消费后置 nil。
    @Published var pendingTopTab: HomeTopTab?

    private init() {}

    /// 请求切到指定 top tab（LiveTabView onChange 消费）
    func requestTopTab(_ tab: HomeTopTab) {
        pendingTopTab = tab
    }
}
