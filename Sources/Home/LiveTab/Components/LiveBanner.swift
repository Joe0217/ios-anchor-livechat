import SwiftUI

/// 首页 banner 位。接受 `AppPictureStore` 派生的 `[AppPictureItem]` 数组。
///
/// 对齐 H5 `views/home/components/banner.vue`：
/// - 空态直接 `EmptyView`（H5 `v-if="bannerList.length"`）
/// - 多张时轮播（H5 `:loop="bannerList?.length > 1"` + Autoplay）
///
struct LiveBanner: View {
    let items: [AppPictureItem]
    var onTap: (AppPictureItem) -> Void = { _ in }
    /// 当前页实际展示时回调。默认 no-op，供 Party 等需要按轮播页做曝光统计的场景使用。
    var onPageDisplayed: (AppPictureItem) -> Void = { _ in }
    /// 是否处于可见/活跃状态。keep-alive 架构下 view 永远不 dismount，autoplay `.task`
    /// 也不会随切走 tab 而 cancel——此参数让父容器（LiveTabView）传"真可见"信号：
    /// `isHomeTabActive && current == .live`；不 active 时 task 立即 return，能耗归零。
    var isActive: Bool = true
    /// 默认沿用首页的 3 秒节奏；Party 首页按 H5 `homeBanner.vue` 传 5 秒。
    var autoplayInterval: TimeInterval = 3
    /// 用户滑动后暂停自动播放，并在该时长后恢复。默认与首页 3 秒轮播周期一致。
    var autoplayResumeDelay: TimeInterval = 3

    /// 多图时在首尾各添加一个哨兵页：滑到哨兵后无动画回填到真页，实现手势和自动播放的连续循环。
    @State private var pageIndex: Int = 1
    @State private var autoplayEnabled = true
    @State private var pageChangeOrigin: PageChangeOrigin?
    @State private var manualInteractionGeneration = 0
    @State private var isManualDragInProgress = false

    private enum PageChangeOrigin {
        case automatic
        case loopCorrection
    }

    /// task id 组合 banner 标识与活跃状态。Banner 数据变更会重启轮播，切换 Home 子 tab 则暂停/恢复当前位置。
    private struct LoopKey: Hashable {
        let itemIDs: [String]
        let active: Bool
        let autoplayEnabled: Bool
        let intervalNanoseconds: UInt64
    }

    private struct ResumeKey: Hashable {
        let interactionGeneration: Int
        let active: Bool
        let resumeDelayNanoseconds: UInt64
    }

    private var loopItems: [AppPictureItem] {
        guard let first = items.first, let last = items.last, items.count > 1 else { return items }
        return [last] + items + [first]
    }

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else if items.count == 1 {
            bannerCard(items[0])
                .onAppear { onPageDisplayed(items[0]) }
        } else {
            TabView(selection: $pageIndex) {
                ForEach(Array(loopItems.enumerated()), id: \.offset) { index, item in
                    bannerCard(item).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .frame(height: Theme.Metric.liveBannerHeight)
            .simultaneousGesture(manualPagingGesture)
            .onChange(of: pageIndex, perform: handlePageChange)
            .onChange(of: items.map(\.id)) { _ in
                pageChangeOrigin = .loopCorrection
                pageIndex = 1
                autoplayEnabled = true
            }
            .task(id: LoopKey(
                itemIDs: items.map(\.id),
                active: isActive,
                autoplayEnabled: autoplayEnabled,
                intervalNanoseconds: autoplayIntervalNanoseconds
            )) {
                guard isActive, autoplayEnabled, items.count > 1 else { return }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: autoplayIntervalNanoseconds)
                    } catch {
                        return
                    }
                    pageChangeOrigin = .automatic
                    withAnimation(.easeInOut(duration: 0.4)) {
                        pageIndex += 1
                    }
                }
            }
            .task(id: ResumeKey(
                interactionGeneration: manualInteractionGeneration,
                active: isActive,
                resumeDelayNanoseconds: autoplayResumeDelayNanoseconds
            )) {
                guard manualInteractionGeneration > 0, isActive else {
                    return
                }
                do {
                    try await Task.sleep(nanoseconds: autoplayResumeDelayNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                autoplayEnabled = true
            }
        }
    }

    private func handlePageChange(_ index: Int) {
        let origin = pageChangeOrigin
        pageChangeOrigin = nil
        let isLoopCorrection: Bool
        if case .loopCorrection? = origin {
            isLoopCorrection = true
        } else {
            isLoopCorrection = false
        }
        if !isLoopCorrection, let displayed = item(atPageIndex: index) {
            onPageDisplayed(displayed)
        }
        if origin == nil {
            pauseAutoplayForManualInteraction()
        }

        let lastSentinelIndex = items.count + 1
        guard index == 0 || index == lastSentinelIndex else { return }
        let destination = index == 0 ? items.count : 1
        DispatchQueue.main.async {
            pageChangeOrigin = .loopCorrection
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pageIndex = destination
            }
        }
    }

    private func item(atPageIndex index: Int) -> AppPictureItem? {
        guard !items.isEmpty else { return nil }
        if index == 0 { return items.last }
        if index == items.count + 1 { return items.first }
        let itemIndex = index - 1
        guard items.indices.contains(itemIndex) else { return nil }
        return items[itemIndex]
    }

    private var autoplayIntervalNanoseconds: UInt64 {
        nanoseconds(for: autoplayInterval)
    }

    private var autoplayResumeDelayNanoseconds: UInt64 {
        nanoseconds(for: autoplayResumeDelay)
    }

    private func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        UInt64(max(0.1, seconds) * 1_000_000_000)
    }

    private var manualPagingGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { _ in
                guard !isManualDragInProgress else { return }
                isManualDragInProgress = true
                pauseAutoplayForManualInteraction()
            }
            .onEnded { _ in
                isManualDragInProgress = false
            }
    }

    private func pauseAutoplayForManualInteraction() {
        // 每次手势递增 generation，会取消上一次尚未完成的恢复计时。
        autoplayEnabled = false
        manualInteractionGeneration += 1
    }

    @ViewBuilder
    private func bannerCard(_ item: AppPictureItem) -> some View {
        if let directUrl = item.directUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !directUrl.isEmpty {
            Button { onTap(item) } label: {
                singleImage(item)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        } else {
            singleImage(item)
        }
    }

    private func singleImage(_ item: AppPictureItem) -> some View {
        CachedAsyncImage(url: item.picURL, contentMode: .fill, persistent: true, cdn: (.custom(width: 800), .fill)) {
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
