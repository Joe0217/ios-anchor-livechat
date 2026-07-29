import SwiftUI
import UIKit

/// Party 房右下角活动资源位。
///
/// 对齐主播端：50pt 方形、多个资源每 3 秒自动轮播、底部粉色分页点；
/// 图片缺失的项目不占位，单条项目不启动轮播任务。
/// 遵循 `.claude/rules/banner-carousel-looping.md`：多项资源支持手动双向循环。
struct PartyRoomBannerCarousel: View {
    let banners: [PartyRoomBanner]
    let onTap: (PartyRoomBanner) -> Void

    @State private var currentIndex = 0
    /// 多页时使用 0=末页副本、1...n=真实页、n+1=首页副本，实现手势跨首尾循环。
    @State private var selectedPage = 1
    @State private var autoplayEnabled = true
    @State private var pageChangeOrigin: PageChangeOrigin?
    @State private var manualInteractionGeneration = 0
    @State private var isManualDragInProgress = false

    private enum PageChangeOrigin {
        case automatic
        case loopCorrection
    }

    private struct LoopKey: Hashable {
        let banners: [String]
        let autoplayEnabled: Bool
    }

    private struct ResumeKey: Hashable {
        let interactionGeneration: Int
    }

    private var displayableBanners: [PartyRoomBanner] {
        banners.filter(\.isDisplayable)
    }

    private var loopKey: [String] {
        displayableBanners.map { "\($0.id ?? "")_\($0.picUrl ?? "")_\($0.directUrl ?? "")" }
    }

    var body: some View {
        let items = displayableBanners
        if !items.isEmpty {
            ZStack(alignment: .top) {
                ZStack(alignment: .bottom) {
                    bannerPager(items: items)

                    if items.count > 1 {
                        pageIndicator(count: items.count)
                            .padding(.bottom, 5)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                if items.indices.contains(currentIndex),
                   let flameURL = items[currentIndex].activeFlameURL {
                    PartyRoomBannerFlame(urlString: flameURL)
                        .allowsHitTesting(false)
                }
            }
            // H5 `party-banner.vue` uses `pt-20`: the 50x16 flame occupies the top
            // reserve, while the tappable 50x50 banner remains at the bottom.
            .frame(width: 50, height: 70, alignment: .bottom)
            .onChange(of: loopKey) { _ in
                pageChangeOrigin = .loopCorrection
                currentIndex = 0
                selectedPage = 1
                autoplayEnabled = true
            }
            .task(id: LoopKey(banners: loopKey, autoplayEnabled: autoplayEnabled)) {
                guard autoplayEnabled, items.count > 1 else { return }

                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { return }
                    advanceBanner(itemCount: items.count)
                }
            }
            .task(id: ResumeKey(interactionGeneration: manualInteractionGeneration)) {
                guard manualInteractionGeneration > 0 else { return }
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                autoplayEnabled = true
            }
        }
    }

    @ViewBuilder
    private func bannerPager(items: [PartyRoomBanner]) -> some View {
        if items.count > 1 {
            TabView(selection: $selectedPage) {
                // 首尾各放一个副本。用户继续滑动时，视觉先完成自然分页，再无动画跳回真实页。
                ForEach(0..<(items.count + 2), id: \.self) { page in
                    let itemIndex = (page - 1 + items.count) % items.count
                    bannerImage(items[itemIndex])
                        .tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .simultaneousGesture(manualPagingGesture)
            .onChange(of: selectedPage) { page in
                handlePageChange(page, itemCount: items.count)
            }
        } else if let banner = items.first {
            bannerImage(banner)
        }
    }

    private func handlePageChange(_ page: Int, itemCount: Int) {
        let origin = pageChangeOrigin
        pageChangeOrigin = nil
        if origin == nil {
            pauseAutoplayForManualInteraction()
        }

        if page == 0 {
            currentIndex = itemCount - 1
            resetLoopPage(from: page, to: itemCount)
        } else if page == itemCount + 1 {
            currentIndex = 0
            resetLoopPage(from: page, to: 1)
        } else {
            currentIndex = page - 1
        }
    }

    private func resetLoopPage(from sentinel: Int, to page: Int) {
        DispatchQueue.main.async {
            guard selectedPage == sentinel else { return }
            pageChangeOrigin = .loopCorrection
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selectedPage = page
            }
        }
    }

    private func advanceBanner(itemCount: Int) {
        let nextPage = currentIndex == itemCount - 1
            ? itemCount + 1
            : currentIndex + 2
        pageChangeOrigin = .automatic
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedPage = nextPage
        }
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
        autoplayEnabled = false
        manualInteractionGeneration += 1
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

/// 主播端 Party 右下角半屏游戏轮播。H5 与活动 Banner 分属两个 50pt 资源位，游戏轮播间隔 5 秒。
/// 遵循 `.claude/rules/banner-carousel-looping.md`：多项内容以首尾哨兵页支持手动双向循环。
struct PartyGameBannerCarousel: View {
    let games: [PartyBannerGame]
    let onTap: (PartyBannerGame) -> Void

    @State private var currentIndex = 0
    /// 0=末页副本，1...n=真实页，n+1=首页副本。逻辑索引仅用于分页点和跳转内容。
    @State private var selectedPage = 1
    @State private var autoplayEnabled = true
    @State private var pageChangeOrigin: PageChangeOrigin?
    @State private var manualInteractionGeneration = 0
    @State private var isManualDragInProgress = false

    private enum PageChangeOrigin {
        case automatic
        case loopCorrection
    }

    private struct LoopKey: Hashable {
        let games: [String]
        let autoplayEnabled: Bool
    }

    private struct ResumeKey: Hashable {
        let interactionGeneration: Int
    }

    private var displayableGames: [PartyBannerGame] {
        games.filter(\.isDisplayable)
    }

    private var loopKey: [String] {
        displayableGames.map {
            [
                $0.id,
                $0.gameId,
                $0.partyIcon ?? "",
                $0.gameLink ?? "",
                $0.gameType ?? "",
                $0.appIds ?? ""
            ]
            .joined(separator: "_")
        }
    }

    var body: some View {
        let items = displayableGames
        if !items.isEmpty {
            ZStack(alignment: .bottom) {
                if items.count > 1 {
                    TabView(selection: $selectedPage) {
                        // 首尾副本让手势先自然完成分页，再无动画修正回真实页。
                        ForEach(0..<(items.count + 2), id: \.self) { page in
                            let itemIndex = (page - 1 + items.count) % items.count
                            gameImage(items[itemIndex])
                                .tag(page)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .simultaneousGesture(manualPagingGesture)
                    .onChange(of: selectedPage) { page in
                        handlePageChange(page, itemCount: items.count)
                    }
                } else if let game = items.first {
                    gameImage(game)
                }

                if items.count > 1 {
                    pageIndicator(count: items.count)
                        .padding(.bottom, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .onChange(of: loopKey) { _ in
                pageChangeOrigin = .loopCorrection
                currentIndex = 0
                selectedPage = 1
                autoplayEnabled = true
            }
            .task(id: LoopKey(games: loopKey, autoplayEnabled: autoplayEnabled)) {
                guard autoplayEnabled, items.count > 1 else { return }

                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { return }
                    advanceGame(itemCount: items.count)
                }
            }
            .task(id: ResumeKey(interactionGeneration: manualInteractionGeneration)) {
                guard manualInteractionGeneration > 0 else { return }
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                autoplayEnabled = true
            }
        }
    }

    private func handlePageChange(_ page: Int, itemCount: Int) {
        let origin = pageChangeOrigin
        pageChangeOrigin = nil
        if origin == nil {
            pauseAutoplayForManualInteraction()
        }

        if page == 0 {
            currentIndex = itemCount - 1
            resetLoopPage(from: page, to: itemCount)
        } else if page == itemCount + 1 {
            currentIndex = 0
            resetLoopPage(from: page, to: 1)
        } else {
            currentIndex = page - 1
        }
    }

    private func resetLoopPage(from sentinel: Int, to page: Int) {
        DispatchQueue.main.async {
            guard selectedPage == sentinel else { return }
            pageChangeOrigin = .loopCorrection
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selectedPage = page
            }
        }
    }

    private func advanceGame(itemCount: Int) {
        let nextPage = currentIndex == itemCount - 1
            ? itemCount + 1
            : currentIndex + 2
        pageChangeOrigin = .automatic
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedPage = nextPage
        }
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
        autoplayEnabled = false
        manualInteractionGeneration += 1
    }

    @ViewBuilder
    private func gameImage(_ game: PartyBannerGame) -> some View {
        let image = CachedAsyncImage(
            url: URL(string: game.partyIcon ?? ""),
            contentMode: .fill,
            persistent: true
        ) {
            Color.clear
        }
        .frame(width: 50, height: 50)
        .clipped()

        if game.isLaunchable {
            Button { onTap(game) } label: { image }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.PartyRoom.a11yGame)
        } else {
            image.accessibilityHidden(true)
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

private struct PartyRoomBannerFlame: View {
    private let url: URL?
    @State private var image: UIImage?

    init(urlString: String) {
        let candidate = URL(string: urlString)
        if let candidate,
           let scheme = candidate.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            url = candidate
            _image = State(initialValue: ImageCache.shared.cached(for: candidate))
        } else {
            url = nil
            _image = State(initialValue: nil)
        }
    }

    var body: some View {
        Group {
            if let image {
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: 50, height: 16)

                    Text(L10n.Party.bannerScoreDouble)
                        .font(.system(size: 7, weight: .medium))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.leading, 10)
                }
                .frame(width: 50, height: 16)
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = await ImageCache.shared.fetch(url)
        }
    }
}

private extension PartyRoomBanner {
    var activeFlameURL: String? {
        guard let activityFlamePic, !activityFlamePic.isEmpty,
              let start = Self.parseFlameDate(flameStartTime),
              let end = Self.parseFlameDate(flameEndTime),
              Date() >= start, Date() <= end else {
            return nil
        }
        return activityFlamePic
    }

    static func parseFlameDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let numeric = Double(raw) {
            let seconds = numeric > 10_000_000_000 ? numeric / 1_000 : numeric
            return Date(timeIntervalSince1970: seconds)
        }
        let iso8601 = ISO8601DateFormatter()
        if let date = iso8601.date(from: raw) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // H5 `new Date("yyyy-MM-dd HH:mm:ss")` treats timezone-less values as local.
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: raw)
    }
}
