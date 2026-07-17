import SwiftUI

/// Daily / Weekly tab 切换。设计稿:**居中偏左排列**,大间距(Daily 靠左,Weekly 靠中)。
/// - 激活态:黄字 15pt semi-bold + 底部黄色下划线(宽度与文字近似)
/// - 非激活:灰字 15pt regular
struct TaskTabBar: View {
    let active: TaskCycle
    let onTap: (TaskCycle) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            tabItem(cycle: .daily, label: L10n.taskCycleDaily)
            Spacer(minLength: 0)
            tabItem(cycle: .weekly, label: L10n.taskCycleWeekly)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
    }

    private func tabItem(cycle: TaskCycle, label: String) -> some View {
        let isActive = active == cycle
        return Button {
            onTap(cycle)
        } label: {
            VStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 15, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Color(hex: 0xFFE600) : .white.opacity(0.5))
                    .fixedSize()
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isActive ? Color(hex: 0xFFE600) : Color.clear)
                    .frame(width: 32, height: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
