import SwiftUI

/// H5 用户端消息公屏 VIP 金色徽章（对齐 H5 chat-list.vue L155 `h12 w32` + 1758252289621.webp）
/// v4（2026-07-15）：从 SF Symbol 占位切换到设计切图 asset。
struct PublicChatVipBadge: View {
    var body: some View {
        Image("publicChatVipBadge")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 32, height: 12)   // 对齐 H5 chat-list.vue L155 尺寸
            .accessibilityLabel("VIP")
    }
}
