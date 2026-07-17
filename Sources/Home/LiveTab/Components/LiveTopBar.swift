import SwiftUI

/// Live Tab 顶部条：4 个子 tab 切换 + 右侧排行榜 / 刷新 / 在线小圆点。
///
/// 刷新按钮 + 在线圆点对齐 H5 `components/tabsNav.vue`：
/// - 点刷新 → `OnlineStatusStore.refreshOnline()`（强制上线 + 1s 旋转 + reconnect toast）
/// - 圆点颜色随 `OnlineStatusStore.isOnline` 变化：绿 `#00D592` / 灰
struct LiveTopBar: View {
    @Binding var selected: HomeTopTab
    /// 按主播段位派生的 tab 顺序 (trial #1 A-spec §3.1)。
    /// S 级：[live, list, match, circle]；非 S 级：[list, match, live, circle]。
    /// 默认值是 S 级顺序，便于 Preview 和兼容性。
    let availableOrder: [HomeTopTab]
    let rankCount: String

    @ObservedObject private var onlineStatus = OnlineStatusStore.shared

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: Theme.Metric.liveSubTabGap) {
                ForEach(availableOrder, id: \.self) { tab in
                    LiveSubTabButton(tab: tab, isSelected: selected == tab) {
                        // P 项目权限管理 v2 code-review Finding 7：optimistic init canCall=true 期间黑名单
                        // 用户 tab bar 可见 Match icon；tap Match 时用 snapshot 挡视觉级绕过（不进 empty hero）
                        if tab == .match && !SelfPermissionBridge.shared.canCallSnapshot { return }
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

            // 刷新按钮：对齐安卓 queryHideState(true, true) —— 1s 旋转 + 查超限 API → 未超限置回上线 + toast / 超限弹 SetToBusyDialog
            Button {
                onlineStatus.refreshOnline()
            } label: {
                Image("liveRefresh")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .rotationEffect(.degrees(onlineStatus.isRefreshing ? 360 : 0))
                    .animation(
                        onlineStatus.isRefreshing
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: onlineStatus.isRefreshing
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.liveRefresh)

            // 在线圆点：对齐安卓 3 色 —— 🟢 绿 online / 🔘 灰 offline / 🔴 红 forcedBusy
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.3))
                    .frame(width: 28, height: 28)
                Circle()
                    .fill(dotColor(onlineStatus.derivedDot))
                    .frame(width: 10, height: 10)
            }
            .accessibilityLabel(L10n.liveOnlineDot)
            .accessibilityValue(dotA11yValue(onlineStatus.derivedDot))
        }
    }

    private func dotColor(_ dot: DotStatus) -> Color {
        switch dot {
        case .online:     return Color(hex: 0x00D592)   // H5 --lc-online-status-leisure
        case .offline:    return Color.gray             // H5 --lc-online-status-off
        case .forcedBusy: return Color(hex: 0xFF3B30)   // 安卓 forcedBusy 红
        }
    }

    private func dotA11yValue(_ dot: DotStatus) -> String {
        switch dot {
        case .online:     return L10n.workOnlineOn
        case .offline:    return L10n.workOnlineOff
        case .forcedBusy: return L10n.setToBusyTitle
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
    let tab: HomeTopTab
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
