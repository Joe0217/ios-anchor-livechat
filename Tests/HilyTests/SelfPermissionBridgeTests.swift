import XCTest
import Combine

/// 覆盖 spec §5 Bridge 层 F-1 ~ F-10 + deny-by-default + snapshot/@Published 一致性 + userType 变化重算。
/// 见 [P-plan-用户权限管理系统-*.md] Task 3。
final class SelfPermissionBridgeTests: XCTestCase {

    // MARK: - Helper

    private func makeBridge() -> (SelfPermissionBridge, CurrentValueSubject<Int?, Never>, CurrentValueSubject<Bool, Never>) {
        let userTypeSubject = CurrentValueSubject<Int?, Never>(nil)
        let loadedSubject = CurrentValueSubject<Bool, Never>(false)
        let bridge = SelfPermissionBridge(
            userTypePublisher: userTypeSubject.eraseToAnyPublisher(),
            loadedPublisher: loadedSubject.eraseToAnyPublisher()
        )
        return (bridge, userTypeSubject, loadedSubject)
    }

    /// 等 sink 双写完成（同步 lock + async MainActor Task）
    private func waitForSink() {
        let exp = expectation(description: "sink propagated")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
    }

    // MARK: - Deny-by-default · loaded=false 全 false

    func test_notLoaded_allCanXFalse() {
        let (bridge, userType, loaded) = makeBridge()
        loaded.send(false)
        userType.send(2)   // 合法 userType 但 loaded=false
        waitForSink()

        XCTAssertFalse(bridge.canCallSnapshot, "loaded=false 时 deny-by-default")
        XCTAssertFalse(bridge.canLiveSnapshot)
        XCTAssertFalse(bridge.canPartySnapshot)
    }

    // MARK: - F-1 ~ F-3: 合法 userType

    func test_userType_2_allCanXTrue() {
        let (bridge, userType, loaded) = makeBridge()
        loaded.send(true)
        userType.send(2)
        waitForSink()

        XCTAssertTrue(bridge.canCallSnapshot)
        XCTAssertTrue(bridge.canLiveSnapshot)
        XCTAssertTrue(bridge.canPartySnapshot)
    }

    func test_userType_9_allCanXTrue() {
        let (bridge, userType, loaded) = makeBridge()
        loaded.send(true)
        userType.send(9)
        waitForSink()

        XCTAssertTrue(bridge.canCallSnapshot)
        XCTAssertTrue(bridge.canLiveSnapshot)
        XCTAssertTrue(bridge.canPartySnapshot)
    }

    // MARK: - F-4 ~ F-9: 六种黑名单 userType

    func test_userType_101_blocksCall() {
        let (bridge, userType, loaded) = makeBridge()
        loaded.send(true); userType.send(101); waitForSink()
        XCTAssertFalse(bridge.canCallSnapshot)
        XCTAssertTrue(bridge.canLiveSnapshot)
        XCTAssertTrue(bridge.canPartySnapshot)
    }

    func test_userType_102_blocksLive() {
        let (bridge, userType, loaded) = makeBridge()
        loaded.send(true); userType.send(102); waitForSink()
        XCTAssertTrue(bridge.canCallSnapshot)
        XCTAssertFalse(bridge.canLiveSnapshot)
        XCTAssertTrue(bridge.canPartySnapshot)
    }

    func test_userType_103_blocksParty() {
        let (bridge, userType, loaded) = makeBridge()
        loaded.send(true); userType.send(103); waitForSink()
        XCTAssertTrue(bridge.canCallSnapshot)
        XCTAssertTrue(bridge.canLiveSnapshot)
        XCTAssertFalse(bridge.canPartySnapshot)
    }

    func test_userType_104_blocksCallAndLive() {
        let (bridge, userType, loaded) = makeBridge()
        loaded.send(true); userType.send(104); waitForSink()
        XCTAssertFalse(bridge.canCallSnapshot)
        XCTAssertFalse(bridge.canLiveSnapshot)
        XCTAssertTrue(bridge.canPartySnapshot)
    }

    func test_userType_105_blocksCallAndParty() {
        let (bridge, userType, loaded) = makeBridge()
        loaded.send(true); userType.send(105); waitForSink()
        XCTAssertFalse(bridge.canCallSnapshot)
        XCTAssertTrue(bridge.canLiveSnapshot)
        XCTAssertFalse(bridge.canPartySnapshot)
    }

    func test_userType_106_blocksLiveAndParty() {
        let (bridge, userType, loaded) = makeBridge()
        loaded.send(true); userType.send(106); waitForSink()
        XCTAssertTrue(bridge.canCallSnapshot)
        XCTAssertFalse(bridge.canLiveSnapshot)
        XCTAssertFalse(bridge.canPartySnapshot)
    }

    // MARK: - Snapshot 与 @Published 双写最终一致

    func test_snapshotAndPublishedEventuallyConsistent() async {
        let (bridge, userType, loaded) = makeBridge()
        loaded.send(true)
        userType.send(101)
        try? await Task.sleep(nanoseconds: 100_000_000)

        await MainActor.run {
            XCTAssertEqual(bridge.canCall, bridge.canCallSnapshot)
            XCTAssertEqual(bridge.canLive, bridge.canLiveSnapshot)
            XCTAssertEqual(bridge.canParty, bridge.canPartySnapshot)
        }
    }

    // MARK: - R-2: userType 变化立即传播（101 → 2 回归 all-true）

    func test_userType_change_recomputes() {
        let (bridge, userType, loaded) = makeBridge()
        loaded.send(true)
        userType.send(101); waitForSink()
        XCTAssertFalse(bridge.canCallSnapshot)

        userType.send(2); waitForSink()
        XCTAssertTrue(bridge.canCallSnapshot, "userType 101 → 2 应恢复 canCall=true")
    }
}
