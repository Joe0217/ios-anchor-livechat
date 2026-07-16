import SwiftUI

/// VIP 徽章 · 全项目通用组件（位于 `Sources/DesignSystem/Badges/`，
/// 对齐 [prefer-shared-component-over-adhoc](../.claude/rules/prefer-shared-component-over-adhoc.md)
/// "公共组件必须在 Sources/Core / DesignSystem 等横向层目录"铁律）。
///
/// **来源**：H5 用户端 `chat-list.vue` / 直播列表 `list.vue`；iOS 侧全 App VIP 视觉统一。
///
/// **Size 两档**：
/// - `.small`  h=12（公屏 marquee 密集场景 / EnterRoomFloat / UserCard，对齐 H5 `chat-list.vue` L155 32×12）
/// - `.medium` h=14（列表/榜单，对齐直播列表 UserCard + PK Rank + 消息列表）
///
/// **调用点**：MessageSessionRow / LiveListUserCard / PKRankSheetView / PublicChat rows（6+）/
/// UserCardPopup / CallView / EnterRoomFloat（共 15 处）。
struct VIPBadge: View {
    enum Size { case small, medium }

    let size: Size

    init(size: Size = .medium) {
        self.size = size
    }

    var body: some View {
        Image("liveListVipBadge")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: size == .small ? 12 : 14)
            .accessibilityLabel(L10n.messageA11yVIP)
    }
}
