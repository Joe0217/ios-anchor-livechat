import SwiftUI

/// 首页：直播流广场（Live 设计稿还原）。
///
/// 顶部子 tab Live/List/Match/Circle 切换由 LiveTabView 自管理。
/// POC 调试入口已移至 Work tab → Tools → Invite 工具，沿用 WorkView 内的 NavigationStack。
struct HomeView: View {
    var body: some View {
        LiveTabView()
    }
}
