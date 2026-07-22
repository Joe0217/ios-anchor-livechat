import SwiftUI

/// H5 `shared-lucky-gift-win-animate.vue` 的中奖文字覆盖层。
///
/// 跟随全局 GiftEffect 队列的当前项：SVGA 开始后延迟 2.6 秒显示，4.5 秒时结束。
/// 放在 GiftEffect overlay window 内可确保文字层级高于正在播放的 SVGA。
struct LuckyGiftWinTextLayer: View {
    @ObservedObject var bridge: GiftEffectCurrentBridge
    @State private var visibleWin: GiftEffectLuckyGiftWin?
    @State private var hasMoved = false

    var body: some View {
        GeometryReader { proxy in
            if let win = visibleWin {
                ZStack {
                    VStack(spacing: 4) {
                        CachedAsyncImage(
                            url: win.senderAvatarUrl.flatMap(URL.init(string:)),
                            contentMode: .fill,
                            persistent: false,
                            cdn: (.avatarSmall, .fill)
                        ) {
                            Circle().fill(Color.white.opacity(0.2))
                        }
                        .frame(width: 52, height: 52)
                        .clipShape(Circle())

                        Text(win.senderNickname)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: 140)

                        CachedAsyncImage(
                            url: URL(string: "https://img.hnhily.link//appId/default/1756883385386.webp"),
                            contentMode: .fit,
                            persistent: true
                        ) {
                            Color.clear
                        }
                        .frame(width: 71, height: 28)
                    }
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.16)

                    Text("x \(win.reward)")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(Color(red: 1.0, green: 0.925, blue: 0.996))
                        .shadow(color: Color(red: 0.5, green: 0.235, blue: 0.094).opacity(0.7), radius: 3)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.55)
                }
                .offset(y: hasMoved ? 24 : 0)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: bridge.current?.id) {
            let currentID = bridge.current?.id
            visibleWin = nil
            hasMoved = false
            guard let currentID,
                  let win = bridge.current?.luckyGiftWin
            else { return }

            do {
                try await Task.sleep(nanoseconds: 2_600_000_000)
                guard !Task.isCancelled, bridge.current?.id == currentID else { return }
                visibleWin = win
                withAnimation(.easeInOut(duration: 1.0)) { hasMoved = true }

                try await Task.sleep(nanoseconds: 1_900_000_000)
                guard !Task.isCancelled, bridge.current?.id == currentID else { return }
                visibleWin = nil
            } catch {
                return
            }
        }
    }
}
