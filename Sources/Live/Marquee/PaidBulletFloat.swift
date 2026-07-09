import SwiftUI

/// 付费弹幕飘屏（对齐 H5 bullet-float-manager.vue 单档简化）
///
/// 位置：屏幕上部（约 top 200pt）
/// 动画：`offset(x:)` 从 +100vw → 0 (0.5s enter) → stay (3s) → -100vw (0.5s leave)
struct PaidBulletFloat: View {
    @ObservedObject var queue: PaidBulletQueue
    let isHost: Bool   // 仅主播可见 dislike 按钮
    @State private var phase: AnimPhase = .initial
    @State private var currentItemId: UUID?

    enum AnimPhase {
        case initial      // 屏幕外右
        case entering     // 移入中心
        case staying      // 停留
        case leaving      // 移出屏幕外左
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let item = queue.current {
                    content(item)
                        .offset(x: computeOffset(width: geo.size.width))
                        .id(item.id)
                        .onAppear {
                            phase = .initial
                            currentItemId = item.id
                            // 一帧后启动动画流水
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 50_000_000)
                                withAnimation(.easeOut(duration: 0.5)) { phase = .entering }
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                phase = .staying
                                try? await Task.sleep(nanoseconds: UInt64(item.stayDuration * 1_000_000_000))
                                withAnimation(.easeIn(duration: 0.5)) { phase = .leaving }
                            }
                        }
                }
            }
            .frame(width: geo.size.width, alignment: .center)
        }
        .frame(height: 44)
        .padding(.top, 200)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(isHost)  // 非主播不响应（dislike 只有主播能点）
    }

    private func computeOffset(width: CGFloat) -> CGFloat {
        switch phase {
        case .initial: return width * 1.1
        case .entering, .staying: return 0
        case .leaving: return -width * 1.1
        }
    }

    private func content(_ item: PaidBulletQueue.Item) -> some View {
        HStack(spacing: 8) {
            AvatarView(urlString: item.senderAvatarUrl, size: 24, kind: .user)
            Text(item.senderNickname)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: 0xEEFF00))
                .lineLimit(1)
                .frame(maxWidth: 80)
            Text(":")
                .font(.system(size: 12))
                .foregroundColor(.white)
            Text(item.content)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .lineLimit(1)
            if isHost {
                Button {
                    // TODO H 里程碑：接 dislike API + 幂等置灰
                } label: {
                    Image(systemName: "hand.thumbsdown.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel(Text(L10n.paidBulletDislike))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(
            LinearGradient(colors: [Color(hex: 0x5300A1, opacity: 0.9),
                                    Color(hex: 0x3800A0, opacity: 0.9)],
                           startPoint: .leading, endPoint: .trailing),
            in: Capsule()
        )
        .frame(width: 275, height: 44)
    }
}
