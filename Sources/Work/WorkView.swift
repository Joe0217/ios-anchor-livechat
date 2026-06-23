import SwiftUI

/// Work（工作台）整屏：周等级 + 概览卡 + 今日收益 + 工具区。
/// 深色背景，纵向滚动，左右安全边距 12pt，区块间距 16pt。
///
/// path 由 MainTabView 上抬持有：Tools 工具区的子页 push（如 Invite → POC 调试台）
/// 仍走 WorkRoute / NavigationLink(value:)，但路由表 `.navigationDestination(for:)`
/// 注册在 MainTabView 的 NavigationStack 根节点，便于 tabbar 感知 push/pop 深度。
struct WorkView: View {
    @StateObject private var vm = WorkViewModel()
    @Binding var path: NavigationPath

    var body: some View {
        ZStack {
            Theme.Palette.screenBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: Theme.Metric.sectionSpacing) {
                    WeeklyLevelHeader(vm: vm)
                    StatCardsRow(vm: vm)
                    TodayIncomeCard(vm: vm)
                    ToolsSection(vm: vm)
                }
                .padding(.horizontal, Theme.Metric.screenMargin)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
    }
}

/// Work 子页路由。当前仅 DEBUG 期的 POC 调试台入口，上线前随 POCDebugView 一起删除。
enum WorkRoute: Hashable {
    case pocDebug
}

#Preview {
    WorkView(path: .constant(NavigationPath()))
}
