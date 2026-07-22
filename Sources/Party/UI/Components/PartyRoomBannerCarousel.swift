import SwiftUI

/// Party 房右下角活动资源位。
///
/// 对齐主播端：50pt 方形、多个资源每 3 秒自动轮播、底部粉色分页点；
/// 图片缺失的项目不占位，单条项目不启动轮播任务。
struct PartyRoomBannerCarousel: View {
    let banners: [PartyRoomBanner]
    let onTap: (PartyRoomBanner) -> Void

    @State private var currentIndex = 0

    private var displayableBanners: [PartyRoomBanner] {
        banners.filter(\.isDisplayable)
    }

    private var loopKey: [String] {
        displayableBanners.map { "\($0.id ?? "")_\($0.picUrl ?? "")_\($0.directUrl ?? "")" }
    }

    var body: some View {
        let items = displayableBanners
        if !items.isEmpty {
            ZStack(alignment: .bottom) {
                TabView(selection: $currentIndex) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, banner in
                        bannerImage(banner)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                if items.count > 1 {
                    pageIndicator(count: items.count)
                        .padding(.bottom, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .task(id: loopKey) {
                currentIndex = 0
                guard items.count > 1 else { return }

                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        currentIndex = (currentIndex + 1) % items.count
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bannerImage(_ banner: PartyRoomBanner) -> some View {
        let image = CachedAsyncImage(
            url: URL(string: banner.picUrl ?? ""),
            contentMode: .fill,
            persistent: true
        ) {
            Color.clear
        }
        .frame(width: 50, height: 50)
        .clipped()

        if banner.isNavigable {
            Button { onTap(banner) } label: { image }
                .buttonStyle(.plain)
        } else {
            image
                .accessibilityHidden(true)
        }
    }

    private func pageIndicator(count: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == currentIndex ? Color(hex: 0xFE00DE) : Color.white.opacity(0.3))
                    .frame(width: 4, height: 4)
            }
        }
    }
}
