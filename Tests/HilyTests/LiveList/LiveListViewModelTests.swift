import XCTest

@MainActor
final class LiveListViewModelTests: XCTestCase {

    // MARK: - 首页加载

    func test_loadFirstPage_success_setsLoadedAndItems() async {
        let fake = FakeLiveListService(pages: [
            [.mock(id: "1"), .mock(id: "2")]
        ])
        let vm = LiveListViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        XCTAssertEqual(vm.loadState, .loaded)
        XCTAssertEqual(vm.items.map(\.id), ["1", "2"])
        // 不足一页 → hasMore=false
        XCTAssertFalse(vm.hasMore)
    }

    func test_loadFirstPage_fullPage_setsHasMoreTrue() async {
        let fake = FakeLiveListService(pages: [
            Array(repeating: 0, count: 20).enumerated().map { LiveListAnchor.mock(id: "p1-\($0.offset)") }
        ])
        let vm = LiveListViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        XCTAssertTrue(vm.hasMore)
    }

    // MARK: - 触底加载

    func test_loadMore_appendsNextPage() async {
        let fake = FakeLiveListService(pages: [
            Array(repeating: 0, count: 20).enumerated().map { LiveListAnchor.mock(id: "p1-\($0.offset)") },
            Array(repeating: 0, count: 20).enumerated().map { LiveListAnchor.mock(id: "p2-\($0.offset)") },
        ])
        let vm = LiveListViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        await vm.loadMore()
        XCTAssertEqual(vm.items.count, 40)
        XCTAssertEqual(vm.items.last?.id, "p2-19")
    }

    func test_loadMore_whenNoMore_isNoOp() async {
        let fake = FakeLiveListService(pages: [
            [.mock(id: "1")]  // 不足一页
        ])
        let vm = LiveListViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        XCTAssertFalse(vm.hasMore)
        await vm.loadMore()
        XCTAssertEqual(vm.items.count, 1)
        XCTAssertEqual(fake.callCount, 1, "loadMore 应跳过不发请求")
    }

    // MARK: - 真分页 fallback

    func test_loadMore_samePageReturned_stopsPaging() async {
        let page1 = Array(repeating: 0, count: 20).enumerated().map { LiveListAnchor.mock(id: "p1-\($0.offset)") }
        let fake = FakeLiveListService(pages: [page1, page1])
        let vm = LiveListViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        await vm.loadMore()
        XCTAssertFalse(vm.hasMore, "服务端返回同样 id → 视为不支持真分页停止")
        XCTAssertEqual(vm.items.count, 20)
    }

    // MARK: - segment 切换

    func test_segmentSwitch_resetsItemsAndTriggersReload() async {
        // 按 keyword 索引，避免"先调一次再调一次"两次同 page=1 返同样数据
        let fake = FakeLiveListService(pagesByKeyword: [
            1: [.mock(id: "online-1")],
            2: [.mock(id: "prime-1")],
        ])
        let vm = LiveListViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        XCTAssertEqual(vm.items.first?.id, "online-1")
        XCTAssertEqual(fake.lastKeyword, 1)

        vm.segment = .prime
        // didSet 触发 Task — 等它跑完
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(vm.items.first?.id, "prime-1")
        XCTAssertEqual(fake.lastKeyword, 2)
    }

    // MARK: - keep-alive 行为：切回已加载 segment 不重发请求

    func test_segmentSwitch_backToLoadedSegment_keepsAliveAndSkipsRefetch() async {
        let fake = FakeLiveListService(pagesByKeyword: [
            1: [.mock(id: "online-1")],
            2: [.mock(id: "prime-1")],
        ])
        let vm = LiveListViewModel(service: fake, pageSize: 20)

        await vm.loadFirstPage()           // online 加载完
        XCTAssertEqual(fake.callCount, 1)
        XCTAssertEqual(vm.items.first?.id, "online-1")

        vm.segment = .prime                 // 切到 prime
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fake.callCount, 2, "prime 首次加载 → 触发 1 次")
        XCTAssertEqual(vm.items.first?.id, "prime-1")

        vm.segment = .online                // 切回 online —— 应直接显示缓存，不发请求
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fake.callCount, 2, "online 已加载过 → keep-alive 不重发")
        XCTAssertEqual(vm.items.first?.id, "online-1", "切回 online 显示上次缓存")
    }

    func test_segmentSwitch_eachKeepsOwnPaging() async {
        // 各 segment 分页位置独立
        let onlineP1 = (0..<20).map { LiveListAnchor.mock(id: "o-\($0)") }
        let onlineP2 = (0..<20).map { LiveListAnchor.mock(id: "o-p2-\($0)") }
        let primeP1 = [LiveListAnchor.mock(id: "p-1")]
        let fake = FakeLiveListService(pagesByKeywordAndPage: [
            "1-1": onlineP1, "1-2": onlineP2,
            "2-1": primeP1,
        ])
        let vm = LiveListViewModel(service: fake, pageSize: 20)

        await vm.loadFirstPage()              // online p1
        await vm.loadMore()                    // online p2
        XCTAssertEqual(vm.items.count, 40, "online 累计 40 条")

        vm.segment = .prime                    // 切到 prime
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(vm.items.count, 1, "prime 1 条")

        vm.segment = .online                    // 切回 online
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(vm.items.count, 40, "online 切回仍是 40 条（分页位置保留）")
    }

    // MARK: - 错误态

    func test_loadFirstPage_failure_setsError() async {
        let fake = FakeLiveListService(error: APIError(code: "9999", message: "Boom"))
        let vm = LiveListViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        if case .error(let m) = vm.loadState {
            XCTAssertEqual(m, "Boom")
        } else {
            XCTFail("expected .error, got \(vm.loadState)")
        }
    }

    func test_retry_afterErrorWithEmpty_reloadsFirstPage() async {
        let fake = FakeLiveListService(error: APIError(code: "9999", message: "Boom"))
        let vm = LiveListViewModel(service: fake, pageSize: 20)
        await vm.loadFirstPage()
        XCTAssertEqual(fake.callCount, 1)
        fake.error = nil
        fake.pages = [[.mock(id: "1")]]
        await vm.retry()
        XCTAssertEqual(vm.items.first?.id, "1")
        XCTAssertEqual(vm.loadState, .loaded)
    }
}

// MARK: - Fakes & helpers

private final class FakeLiveListService: LiveListServiceProtocol {
    var pages: [[LiveListAnchor]]
    /// segment-aware：keyword → page 1 数据。优先级高于 `pages`（如设置）。
    var pagesByKeyword: [Int: [LiveListAnchor]]?
    /// segment + page 双键索引："{keyword}-{page}" → 数据。优先级最高。
    var pagesByKeywordAndPage: [String: [LiveListAnchor]]?
    var error: APIError?
    var callCount = 0
    var lastKeyword: Int?

    init(pages: [[LiveListAnchor]] = [], error: APIError? = nil) {
        self.pages = pages
        self.error = error
    }

    init(pagesByKeyword: [Int: [LiveListAnchor]]) {
        self.pages = []
        self.pagesByKeyword = pagesByKeyword
    }

    init(pagesByKeywordAndPage: [String: [LiveListAnchor]]) {
        self.pages = []
        self.pagesByKeywordAndPage = pagesByKeywordAndPage
    }

    func fetchUsers(keyword: Int, currentPage: Int, pageSize: Int) async throws -> [LiveListAnchor] {
        callCount += 1
        lastKeyword = keyword
        if let e = error { throw e }
        if let byKeyPage = pagesByKeywordAndPage {
            return byKeyPage["\(keyword)-\(currentPage)"] ?? []
        }
        if let byKey = pagesByKeyword {
            return byKey[keyword] ?? []
        }
        let idx = min(currentPage - 1, pages.count - 1)
        guard idx >= 0 else { return [] }
        return pages[idx]
    }
}

private extension LiveListAnchor {
    static func mock(id: String) -> LiveListAnchor {
        LiveListAnchor(userId: id, nickname: "u\(id)", icon: nil,
                       userLevel: "1", vipExpireTimeMs: nil,
                       country: "US", yxAccid: "yx-\(id)")
    }
}
