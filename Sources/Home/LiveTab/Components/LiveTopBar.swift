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
            // 排行榜徽章（金冠 + +100K）。显式约束宽度防 i18n（ar/tr）后右侧拥挤。
            Image("liveRankBadge")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 28)
                .accessibilityLabel(L10n.liveRankBadge)

            // 刷新按钮（静态还原期：空 action 无业务响应；不用 .disabled 避免切图被 SwiftUI 灰化）
            Button {
                // 占位
            } label: {
                Image("liveRefresh")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
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

/// 单个子 tab 按钮。
///
/// 设计要点：
/// 1. 光带 indicator 用 `.background` 放到 **z 轴下方**（文字渲染在光带之上）。
///    用 `.overlay` 会反过来盖住文字。
/// 2. 选中/未选中字号不同（18pt / 16pt），切换会让文字宽度变化、兄弟 tab 漂移。
///    用 ZStack 叠一个 **不可见的 18pt 占位 Text**，按钮宽度永远按选中态测，
///    与当前是否选中无关。
/// 3. 光带 60×26 居中对齐文字，可视觉横向超出文字两侧（background 不参与父布局）。
struct LiveSubTabButton: View {
    let tab: LiveSubTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // 不可见占位：按选中态 18pt 字号永久占宽度，避免选中切换时按钮宽度抖动
                Text(tab.label)
                    .font(Theme.Typography.liveSubTabActive)
                    .lineLimit(1)
                    .opacity(0)
                    .accessibilityHidden(true)

                // 可见文字：按当前态字号 + 颜色渲染。z 轴在光带之上
                labelText
            }
            .fixedSize()
            .background {
                // 光带：z 轴下方（background）+ 居中对齐 + 不参与父布局尺寸
                if isSelected {
                    Image("liveTabIndicator")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 60, height: 26)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Button 已自带 .isButton trait；只在选中态额外加 .isSelected
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var labelText: some View {
        if isSelected {
            Text(tab.label)
                .font(Theme.Typography.liveSubTabActive)
                .foregroundStyle(Theme.Gradients.liveSubTabText)
                .lineLimit(1)
        } else {
            Text(tab.label)
                .font(Theme.Typography.liveSubTabInactive)
                .foregroundStyle(Theme.Palette.liveSubTabUnselected.opacity(0.85))
                .lineLimit(1)
        }
    }
}
