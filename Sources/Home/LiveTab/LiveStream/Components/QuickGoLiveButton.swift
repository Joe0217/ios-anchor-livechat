import SwiftUI

/// Live 子 tab 右下角快速开播浮动按钮（对齐 H5 `CGoLive` + `FloatButtons`）。
///
/// **行为**：
/// - 点击 → 通过 `QuickGoLiveAction` environment action 触发跨 tab 导航
/// - 目标：切到 Work tab → push `LiveSettingsView`（复用 B 里程碑既有入口）
/// - IM offline 前置校验交给 `LiveSettingsView.prepare` 内部处理（`prepare.imOffline` 文案）
///
/// **仅在 Live 子 tab 显示**（由父容器控制，本组件不感知 tab 状态）。
///
/// 视觉：50pt 图标，无背景（切图本身自带视觉造型）。**RTL 自动镜像**（不用手写
/// `leading/trailing`——父容器 `.overlay(alignment: .bottomTrailing)` 会随 layout direction 反转）。
struct QuickGoLiveButton: View {
    @Environment(\.quickGoLive) private var quickGoLive

    var body: some View {
        Button {
            quickGoLive.perform()
        } label: {
            CDNAssetImage("homeFloatGoLive")
                .resizable()
                .scaledToFit()
                .frame(width: 50, height: 50)
                .accessibilityLabel(L10n.toolGoLive)
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
struct QuickGoLiveButton_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Theme.Palette.liveBottomDark.ignoresSafeArea()
            QuickGoLiveButton()
        }
        .preferredColorScheme(.dark)
    }
}
#endif
