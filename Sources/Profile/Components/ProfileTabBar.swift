import SwiftUI

/// Album / Gifts / Moment 内容 tab。
/// 选中态：黄色加粗 + 下方短金色横线。
struct ProfileTabBar: View {
    @Binding var selected: ProfileTab

    var body: some View {
        HStack(spacing: Theme.Metric.profileTabGap) {
            ForEach(ProfileTab.allCases, id: \.self) { tab in
                Button { selected = tab } label: {
                    tabLabel(for: tab)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected == tab ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metric.profileDescPadding)
    }

    private func tabLabel(for tab: ProfileTab) -> some View {
        let isSelected = selected == tab
        return VStack(spacing: 6) {
            Text(tab.title)
                .font(isSelected ? Theme.Typography.profileTabActive : Theme.Typography.profileTabInactive)
                .foregroundColor(isSelected ? Theme.Palette.profileTabActive : Theme.Palette.profileTabInactive)
            // 仅选中态显示底部短横线
            Capsule()
                .fill(Theme.Palette.profileTabActive)
                .frame(width: 20, height: 3)
                .opacity(isSelected ? 1 : 0)
        }
    }
}
