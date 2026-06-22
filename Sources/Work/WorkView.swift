import SwiftUI

/// Work（工作台）整屏：周等级 + 概览卡 + 今日收益 + 工具区。
/// 深色背景，纵向滚动，左右安全边距 12pt，区块间距 16pt。
struct WorkView: View {
    @StateObject private var vm = WorkViewModel()

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

#Preview {
    WorkView()
}
