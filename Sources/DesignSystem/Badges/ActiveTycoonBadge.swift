import SwiftUI

/// 活跃大 R (Active Tycoon) 徽章 · 全项目通用组件（位于 `Sources/DesignSystem/Badges/`，
/// 对齐 [prefer-shared-component-over-adhoc](../.claude/rules/prefer-shared-component-over-adhoc.md)
/// "公共组件必须在 Sources/Core / DesignSystem 等横向层目录"铁律）。
///
/// **来源（H5 蓝本 §9.6）**：`components/common/c-active-tycoon-badge.vue`。
/// H5 用 3 种 locale 静态图；iOS 只支持 en / ar / tr，暂用两种视觉方案：
/// - `.boltIcon`（Message 私聊列表默认）：宝石/闪电 icon + 粉红 gradient，紧凑
/// - `.bigRText`（直播间榜/名片/公屏）：`BIG R` 大写文本 + 橙红 gradient，capsule
///
/// **可见性铁律**：**仅主态直播 rendering**（`.bigRText` 场景）；`.boltIcon` 用于 Message 私聊列表。
/// 由 caller 控制门禁，本组件无 gating。
///
/// **调用点**（7+ 处，跨业务模块）：`RowRegularText` / `RowEnterRoom` / `RowGift` / `UserCardPopup`
/// / `UserWeeklyRankSheetView` / `EnterRoomFloat` / `MessageSessionRow`
struct ActiveTycoonBadge: View {
    enum Style { case boltIcon, bigRText }
    enum Size { case small, medium }

    let style: Style
    let size: Size

    init(style: Style = .boltIcon, size: Size = .medium) {
        self.style = style
        self.size = size
    }

    var body: some View {
        switch style {
        case .boltIcon:
            Image(systemName: "bolt.fill")
                .font(.system(size: iconFontSize, weight: .semibold))
                .foregroundStyle(.white)
                .padding(iconPadding)
                .background(
                    LinearGradient(colors: [Color(hex: 0xFF6B6B), Color(hex: 0xE94E77)],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(Capsule())
                .accessibilityLabel(L10n.messageA11yActiveTycoon)
        case .bigRText:
            Text("BIG R")
                .font(.system(size: textFontSize, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, textHPadding).padding(.vertical, textVPadding)
                .background(
                    LinearGradient(colors: [Color(hex: 0xFF6B00), Color(hex: 0xFF3D00)],
                                   startPoint: .leading, endPoint: .trailing),
                    in: Capsule()
                )
                .accessibilityLabel(L10n.messageA11yActiveTycoon)
        }
    }

    // MARK: - Sizing

    private var iconFontSize: CGFloat { size == .small ? 8 : 10 }
    private var iconPadding: CGFloat { size == .small ? 2 : 3 }
    private var textFontSize: CGFloat { size == .small ? 9 : 11 }
    private var textHPadding: CGFloat { size == .small ? 4 : 6 }
    private var textVPadding: CGFloat { size == .small ? 1 : 2 }
}
