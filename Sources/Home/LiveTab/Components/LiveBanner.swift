import SwiftUI

/// 首页 banner 位。接受 `AppPictureStore` 派生的 `[AppPictureItem]` 数组。
///
/// 对齐 H5 `views/home/components/banner.vue`：
/// - 空态直接 `EmptyView`（H5 `v-if="bannerList.length"`）
/// - 多张时轮播（H5 `:loop="bannerList?.length > 1"` + Autoplay）
///
/// 卡片点击**本次不做**（客态直播间独立里程碑；banner 跳转 iframe 也需要 J 里程碑内嵌浏览器基建）——
/// 目前仅作视觉展示，点击无响应，与 Live 卡片保持一致的处理原则。
struct LiveBanner: View {
    let items: [AppPictureItem]

    @State private var currentIndex: Int = 0

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else if items.count == 1 {
            singleImage(items[0])
        } else {
            TabView(selection: $currentIndex) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    singleImage(item).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .frame(height: Theme.Metric.liveBannerHeight)
            // autoplay：.task(id:) 让 SwiftUI 托管 Task 生命周期——view 消失 / items.count 变化
            // 自动 cancel 旧循环起新循环，避免 onAppear + 裸 Task {} 累积僵尸 Task（202607031151 审查建议-1）
            .task(id: items.count) {
                guard items.count > 1 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if Task.isCancelled { break }
                    withAnimation(.easeInOut(duration: 0.4)) {
                        currentIndex = (currentIndex + 1) % max(items.count, 1)
                    }
                }
            }
        }
    }

    private func singleImage(_ item: AppPictureItem) -> some View {
        CachedAsyncImage(url: item.picURL, contentMode: .fill, persistent: false) {
            placeholderGradient
        }
        .frame(height: Theme.Metric.liveBannerHeight)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.liveBanner, style: .continuous))
        .accessibilityLabel(L10n.liveBannerA11y)
    }

    private var placeholderGradient: some View {
        LinearGradient(
            colors: [Theme.Palette.liveBannerFill, Color(hex: 0x3B1452)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

#if DEBUG
struct LiveBanner_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            LiveBanner(items: [
                AppPictureItem(id: "1", picUrl: nil, directUrl: nil, bannerPosition: ["首页"])
            ])
            LiveBanner(items: (1...3).map {
                AppPictureItem(id: "\($0)", picUrl: nil, directUrl: nil, bannerPosition: ["首页"])
            })
        }
        .padding()
        .background(Theme.Palette.liveBottomDark)
        .preferredColorScheme(.dark)
    }
}
#endif
