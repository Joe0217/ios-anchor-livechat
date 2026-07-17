import XCTest

/// trial #1 (A-spec §3.1 + §4.1/§4.2/§5.12) — HomeTopTabStore 单测。
///
/// 覆盖：
/// - 冷启动竟态：段位未就绪态 (§5.12)
/// - S 级派生顺序 (§4.1)
/// - 非 S 级派生顺序 (§4.2)
/// - tap / swipe 切换 (§3.1)
/// - 段位刷新保留 userSelected 业务语义 (§3.1 / §5.12)
@MainActor
final class HomeTopTabStoreTests: XCTestCase {

    // MARK: - 冷启动竞态 (§5.12)

    func test_initial_tierUnknown_availableOrderIsNil() {
        let store = HomeTopTabStore()
        XCTAssertNil(store.availableOrder)
        XCTAssertNil(store.currentOuter)
    }

    func test_initial_tierUnknown_tapDoesNothing() {
        // 段位未就绪时 tap 应被忽略 (View 层应展示 loading 不可点)
        let store = HomeTopTabStore()
        store.tapOuter(.live)
        XCTAssertNil(store.currentOuter)
    }

    // MARK: - S 级派生 (§4.1)

    func test_applyTier_sLevel_orderIsLiveListMatchCircle() {
        let store = HomeTopTabStore()
        store.applyTier(isSLevel: true, canCall: true)
        XCTAssertEqual(store.availableOrder, [.live, .list, .match, .circle])
    }

    func test_applyTier_sLevel_defaultSelectFirstLive() {
        let store = HomeTopTabStore()
        store.applyTier(isSLevel: true, canCall: true)
        XCTAssertEqual(store.currentOuter, .live)
    }

    // MARK: - 非 S 级派生 (§4.2)

    func test_applyTier_nonSLevel_orderIsListMatchLiveCircle() {
        let store = HomeTopTabStore()
        store.applyTier(isSLevel: false, canCall: true)
        XCTAssertEqual(store.availableOrder, [.list, .match, .live, .circle])
    }

    func test_applyTier_nonSLevel_defaultSelectFirstList() {
        let store = HomeTopTabStore()
        store.applyTier(isSLevel: false, canCall: true)
        XCTAssertEqual(store.currentOuter, .list)
    }

    // MARK: - tap / swipe (§3.1)

    func test_tapOuter_changesSelection() {
        let store = HomeTopTabStore(initialIsSLevel: true)
        store.tapOuter(.circle)
        XCTAssertEqual(store.currentOuter, .circle)
    }

    func test_swipeOuter_byIndexMapsToEnum_sLevel() {
        let store = HomeTopTabStore(initialIsSLevel: true)
        store.swipeOuter(toIndex: 3) // [live,list,match,circle][3] = circle
        XCTAssertEqual(store.currentOuter, .circle)
    }

    func test_swipeOuter_byIndexMapsToEnum_nonSLevel() {
        let store = HomeTopTabStore(initialIsSLevel: false)
        store.swipeOuter(toIndex: 2) // [list,match,live,circle][2] = live
        XCTAssertEqual(store.currentOuter, .live)
    }

    func test_swipeOuter_outOfBounds_isIgnored() {
        let store = HomeTopTabStore(initialIsSLevel: true)
        store.tapOuter(.list)
        store.swipeOuter(toIndex: 99)
        XCTAssertEqual(store.currentOuter, .list) // 保持
    }

    // MARK: - 段位刷新保留 userSelected (§3.1 / §5.12)

    func test_applyTier_repeat_preservesUserSelected() {
        let store = HomeTopTabStore(initialIsSLevel: true)
        store.tapOuter(.circle)
        XCTAssertEqual(store.currentOuter, .circle)

        // 段位刷新 (例：远程信息后到达，仍是 S 级)
        store.applyTier(isSLevel: true, canCall: true)
        XCTAssertEqual(store.currentOuter, .circle, "用户曾选 circle 应保留")
    }

    func test_applyTier_sToNonS_userSelectedStillInOrder_preserved() {
        // S 级 / 非 S 级 order 都含 .circle、.live、.list、.match —— 用户曾选的 tab
        // 在新 order 中仍存在 → 保留业务语义 (不动 enum 值，仅 index 重映)
        let store = HomeTopTabStore(initialIsSLevel: true)
        store.tapOuter(.live)  // S 级 index 0
        store.applyTier(isSLevel: false, canCall: true) // 非 S 级 → [list,match,live,circle] live 现在 index 2
        XCTAssertEqual(store.currentOuter, .live, "用户曾选 live 应在新 order 保留")
        XCTAssertEqual(store.availableOrder, [.list, .match, .live, .circle])
    }

    // MARK: - 冷启动竟态完整路径 (§5.12)

    func test_coldStart_tierLoadingThenArrival_setsAvailableAndSelection() {
        let store = HomeTopTabStore()
        // 阶段 1: 段位未就绪
        XCTAssertNil(store.availableOrder)
        XCTAssertNil(store.currentOuter)
        // 阶段 2: 段位到达 (S 级)
        store.applyTier(isSLevel: true, canCall: true)
        XCTAssertEqual(store.availableOrder, [.live, .list, .match, .circle])
        XCTAssertEqual(store.currentOuter, .live)
    }
}
