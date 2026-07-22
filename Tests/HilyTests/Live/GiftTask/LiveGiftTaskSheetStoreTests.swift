import XCTest

/// spec §1.4 tc-1a-20~22 · LiveGiftTaskSheetStore(纯 UI 状态,无副作用)。
@MainActor
final class LiveGiftTaskSheetStoreTests: XCTestCase {

    func testInitialState() {
        let store = LiveGiftTaskSheetStore()
        XCTAssertEqual(store.activeTab, .liveGift)
        XCTAssertFalse(store.showRule)
    }

    // tc-1a-20: onPresent 强制重置 activeTab=.liveGift
    func testOnPresent_resetsToLiveGift() {
        let store = LiveGiftTaskSheetStore()
        // 先切到 Tycoon
        store.switchTab(.activeTycoon)
        XCTAssertEqual(store.activeTab, .activeTycoon)

        // present 应重置
        store.onPresent()
        XCTAssertEqual(store.activeTab, .liveGift)
    }

    // tc-1a-21/22: switchTab 幂等 + 切换
    func testSwitchTab_idempotent() {
        let store = LiveGiftTaskSheetStore()
        store.switchTab(.liveGift)   // 同态,不变
        XCTAssertEqual(store.activeTab, .liveGift)

        store.switchTab(.activeTycoon)
        XCTAssertEqual(store.activeTab, .activeTycoon)

        store.switchTab(.liveGift)
        XCTAssertEqual(store.activeTab, .liveGift)
    }

    func testShowRuleToggle() {
        let store = LiveGiftTaskSheetStore()
        store.showRule = true
        XCTAssertTrue(store.showRule)
        store.showRule = false
        XCTAssertFalse(store.showRule)
    }

    func testReset() {
        let store = LiveGiftTaskSheetStore()
        store.switchTab(.activeTycoon)
        store.showRule = true

        store.reset()
        XCTAssertEqual(store.activeTab, .liveGift)
        XCTAssertFalse(store.showRule)
    }
}
