import SwiftUI

/// 派对房身份标识徽章（对齐 H5 `icon_lv_${roomRoleType}.png`）。
///
/// H5 蓝本：
/// - `audio-wrap.vue:172` / `video-seat-cell.vue:59`（麦位）
/// - `message-user.vue:57` / `chat-list.vue:161`（公屏消息 sender 后）
/// - 显示条件：`roomRoleType && roomRoleType < 3`（1=房主 / 2=房管；3=audience 不显示）
///
/// icon URL：
/// - `roomRoleType=1` → `icon_lv_1.png`（房主，麦克风图标）
/// - `roomRoleType=2` → `icon_lv_2.png`（房管，管理员图标）
///
/// 用 `CachedAsyncImage(persistent: true)` — 首次进房拉一次后**内存 + 磁盘缓存永久命中**，
/// 后续所有麦位/消息复用同一张图无网络延迟。
struct PartyRoleBadge: View {
    /// 服务端 roomRoleType（1=owner / 2=admin / 3=audience / nil）
    let roomRoleType: Int?
    /// 显示尺寸；麦位默认 12pt，公屏消息默认 16pt（H5 蓝本 h12/w12 vs h16/w16）
    var size: CGFloat = 12

    var body: some View {
        if let type = roomRoleType, type >= 1, type <= 2,
           let url = URL(string: "https://img.hnhily.link/mstatic/party/icon_lv_\(type).png") {
            CachedAsyncImage(url: url, contentMode: .fit, persistent: true) {
                Color.clear
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }
}
