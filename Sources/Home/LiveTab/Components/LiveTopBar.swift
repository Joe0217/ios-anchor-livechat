import SwiftUI

/// Live Tab 顶部条：4 个子 tab 切换 + 右侧排行榜 / 刷新 / 在线小圆点。
/// 设计稿里 "Live" 选中态文字为橙金渐变，下方贴一条 liveTabIndicator 光带。
struct LiveTopBar: View {
    @Binding var selected: LiveSubTab
    let rankCount: String

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: Theme.Metric.liveSubTabGap) {
                ForEach(LiveSubTab.allCases, id: \.self) { tab in
                    LiveSubTabButton(tab: tab, isSelected: selected == tab) {
                        selected = tab
                    }
                }
            }
            Spacer(minLength: 8)
            rightActions
        }
        .padding(.horizontal, Theme.Metric.liveScreenMargin)
        .padding(.top, 4)
    }

    private var rightActions: some View {
        HStack(spacing: Theme.Metric.liveTopActionGap) {
            // 排行榜徽章（金冠 + +100K）
            Image("liveRankBadge")
                .resizable()
                .scaledToFit()
                .frame(height: 28)
                .accessibilityLabel(L10n.liveRankBadge)

            // 刷新按钮（静态还原期：disabled 防误触；后续接刷新逻辑时移除 .disabled）
            Button {
                // 占位
            } label: {
                Image("liveRefresh")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .accessibilityLabel(L10n.liveRefresh)

            // 在线状态小圆点
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.3))
                    .frame(width: 28, height: 28)
                Circle()
                    .fill(Theme.Palette.liveOnlineDot)
                    .frame(width: 10, height: 10)
            }
            .accessibilityLabel(L10n.liveOnlineDot)
        }
    }
}

/// 单个子 tab 按钮（含选中态下的橙金光带）。
struct LiveSubTabButton: View {
    let tab: LiveSubTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                labelText
                indicator
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var labelText: some View {
        if isSelected {
            Text(tab.label)
                .font(Theme.Typography.liveSubTab)
                .foregroundStyle(Theme.Gradients.liveSubTabText)
                .lineLimit(1)
                .fixedSize()
        } else {
            Text(tab.label)
                .font(Theme.Typography.liveSubTab)
                .foregroundStyle(Theme.Palette.liveSubTabUnselected.opacity(0.85))
                .lineLimit(1)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var indicator: some View {
        if isSelected {
            Image("liveTabIndicator")
                .resizable()
                .scaledToFit()
                .frame(height: 6)
                .frame(maxWidth: 44)
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(height: 6)
        }
    }
}
