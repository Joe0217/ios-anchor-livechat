import SwiftUI

/// 送礼动画 overlay 视觉容器（v8 Stub —— H 礼物会话 replace 真 SVGA 播放器）
///
/// 视觉：中央半屏卡片，显示送礼者头像 + 昵称 + 礼物名 + 数量 + 大礼物 SF Symbol 缩放动画
/// 显示条件：`queue.current != nil`；current 变化时 `.transition(.opacity + scale)` 出入场
///
/// **DEBUG 徽章**：显示 "Stub / SVGA TBD" 提示，避免误认为已完整
struct GiftAnimationOverlay: View {
    @ObservedObject var queue: GiftAnimationQueue

    var body: some View {
        ZStack {
            if let item = queue.current {
                giftCard(item)
                    .transition(.scale.combined(with: .opacity))
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: item.id)
            }
        }
        .allowsHitTesting(false)   // overlay 不拦截触摸
    }

    private func giftCard(_ item: GiftAnimationQueue.Item) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                AvatarView(urlString: item.senderAvatarUrl, size: 32, kind: .user)
                Text(item.senderNickname)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(L10n.publicScreenSentAction)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
            }

            // 大礼物图 + 数量（H 里程碑替换为真 SVGA 播放）
            Image(systemName: "gift.fill")
                .font(.system(size: 64))
                .foregroundColor(Color(hex: 0xFFE600))
                .shadow(color: Color(hex: 0xFFBB02, opacity: 0.6), radius: 12)

            HStack(spacing: 4) {
                Text(item.giftName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                Text("×\(item.count)")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundColor(Color(hex: 0xFFE600))
            }

            #if DEBUG
            Text("Stub / SVGA TBD")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.black.opacity(0.4), in: Capsule())
            #endif
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
        .background(
            LinearGradient(colors: [Color(hex: 0x5300A1, opacity: 0.85),
                                    Color(hex: 0x3800A0, opacity: 0.85)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .frame(maxWidth: 280)
    }
}
