import XCTest

/// trial #1 (A-spec §3.2 + §4.5/§4.6) — CircleStore 单测。
@MainActor
final class CircleStoreTests: XCTestCase {

    func test_initial_isOfficial() {
        // §4.5: 进入 Circle 默认选中 Official (对齐 H5 circle/index.vue:25)
        let store = CircleStore()
        XCTAssertEqual(store.currentSub, .official)
    }

    func test_select_changesCurrentSub() {
        // §4.6: 点击 / 横滑 Circle 子 tab 到 Moment
        let store = CircleStore()
        store.select(.moment)
        XCTAssertEqual(store.currentSub, .moment)
    }

    func test_swipeSub_byIndexMapsToEnum() {
        // SwipeSub(0) → official, SwipeSub(1) → moment, SwipeSub(2) → me
        let store = CircleStore()
        store.swipeSub(toIndex: 1)
        XCTAssertEqual(store.currentSub, .moment)
        store.swipeSub(toIndex: 2)
        XCTAssertEqual(store.currentSub, .me)
        store.swipeSub(toIndex: 0)
        XCTAssertEqual(store.currentSub, .official)
    }

    func test_swipeSub_outOfBounds_isIgnored() {
        let store = CircleStore()
        store.select(.moment)
        store.swipeSub(toIndex: 99)
        XCTAssertEqual(store.currentSub, .moment)
    }

    func test_circleSubTab_officalType_mapsToBackend() {
        // 验证业务概念词表映射 (spec §2.1)
        XCTAssertEqual(CircleSubTab.official.officalType, 1)
        XCTAssertEqual(CircleSubTab.moment.officalType, 2)
        XCTAssertEqual(CircleSubTab.me.officalType, 3)
    }
}
