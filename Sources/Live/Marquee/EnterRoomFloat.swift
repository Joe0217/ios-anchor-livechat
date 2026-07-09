import SwiftUI

/// 用户进场飘屏（对齐 H5 userEntranceFloat.vue）
///
/// 位置：屏幕底部约 40%（对齐 H5 `bottom-40%`）
/// 动画：进入时 opacity 0→1；4s 后 opacity 1→0 + offset(x: -30) + blur → 消失（对齐 H5 fadeLeft 5s ease-in）
struct EnterRoomFloat: View {
    @ObservedObject var queue: EnterRoomFloatQueue
    @State private var phase: AnimPhase = .entering

    enum AnimPhase {
        case entering   // 0-80% 显示
        case leaving    // 80-100% 淡出 + 左移
    }

    var body: some View {
        ZStack {
            if let item = queue.current {
                content(item)
                    .id(item.id)
                    .transition(.opacity)
                    .onAppear {
                        phase = .entering
                        // 4s 后进入淡出阶段
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 4_000_000_000)
                            withAnimation(.easeIn(duration: 1.0)) { phase = .leaving }
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 200)   // H5 `bottom-40%` iPhone 上约 200pt
        .allowsHitTesting(false)
    }

    private func content(_ item: EnterRoomFloatQueue.Item) -> some View {
        HStack(spacing: 8) {
            AvatarView(urlString: item.avatarUrl, size: 32, kind: .user)
            LevelBadge(level: item.userLevel)
            if item.isVip { VipBadge() }
            Text(item.nickname)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(hex: 0x1AFFCD))
                .lineLimit(1)
            Text(L10n.publicScreenEnteredRoom)
                .font(.system(size: 12))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: item.isActiveTycoon
                    ? [Color(hex: 0xFFBB02, opacity: 0.9), Color(hex: 0xFFE600, opacity: 0.6)]   // 大R 金色
                    : [Color(hex: 0x5300A1, opacity: 0.8), Color(hex: 0x3800A0, opacity: 0.5)], // 普通紫色
                startPoint: .leading, endPoint: .trailing
            ),
            in: Capsule()
        )
        .opacity(phase == .leaving ? 0 : 1)
        .offset(x: phase == .leaving ? -30 : 0)
        .blur(radius: phase == .leaving ? 1 : 0)
    }
}
