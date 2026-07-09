import SwiftUI

/// 钻石盲盒飘屏（对齐 H5 diamond-gift-float-screen.vue）
///
/// 位置：屏幕顶部 10%
/// 动画：`offset(x:)` 从 -100vw → +100vw，5s ease-in-out（对齐 H5 translateX -110% → 110%）
struct DiamondGiftFloatScreen: View {
    @ObservedObject var queue: DiamondGiftFloatQueue
    @State private var offsetX: CGFloat = 0
    @State private var currentItemId: UUID?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let item = queue.current {
                    content(item)
                        .offset(x: offsetX)
                        .onAppear {
                            // 初始位置：屏幕外左侧
                            offsetX = -geo.size.width * 1.1
                            currentItemId = item.id
                            // 一帧后开始动画到屏幕外右侧
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 50_000_000)
                                withAnimation(.easeInOut(duration: 5.0)) {
                                    offsetX = geo.size.width * 1.1
                                }
                            }
                        }
                        .id(item.id)
                }
            }
            .frame(width: geo.size.width, alignment: .center)
        }
        .frame(height: 44)
        .padding(.top, 60)   // H5 top-10% iPhone 上约 60pt
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    private func content(_ item: DiamondGiftFloatQueue.Item) -> some View {
        HStack(spacing: 6) {
            Text(item.senderNickname)
                .font(.system(size: 14, weight: .heavy))
                .foregroundColor(Color(hex: 0xFFF28E))
                .lineLimit(1)
                .frame(maxWidth: 100, alignment: .leading)
            Text(L10n.publicScreenSentAction)
                .font(.system(size: 12))
                .foregroundColor(.white)
            Image("liveRoomDiamondBadge")
                .resizable().frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text("×\(item.giftCount)")
                .font(.system(size: 18, weight: .heavy))
                .foregroundColor(Color(hex: 0xFFC83B))
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(
            LinearGradient(colors: [Color(hex: 0xFF0090, opacity: 0.8),
                                    Color(hex: 0xFFBB02, opacity: 0.8)],
                           startPoint: .leading, endPoint: .trailing),
            in: Capsule()
        )
    }
}
