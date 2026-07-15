import SwiftUI

/// 派对房身份徽章（对齐 H5 `message-user.vue:57` + `chat-list.vue:161`：
/// `<g-img v-if="item.role && item.role < 3" :src="icon_lv_${item.role}.png" class="ms4 h16 w16" />`）。
///
/// - `role=.owner (1)` → 房主 mic icon（`icon_lv_1.png`）
/// - `role=.manager (2)` → 房管 icon（`icon_lv_2.png`）
/// - nil → 不显示（Live 场景不填 role，此 badge 完全隐形）
///
/// `CachedAsyncImage(persistent: true)` 拉一次后跨房间跨消息全 hit 缓存。
struct PublicChatRoleBadge: View {
    let role: PartyRole?
    var size: CGFloat = 16

    var body: some View {
        if let role,
           let url = URL(string: "https://img.hnhily.link/mstatic/party/icon_lv_\(role.rawValue).png") {
            CachedAsyncImage(url: url, contentMode: .fit, persistent: true) {
                Color.clear
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }
}
