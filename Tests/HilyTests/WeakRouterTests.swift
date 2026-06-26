import XCTest

/// H 里程碑 M1-10 WeakRouter 弱引用包装单测（spec §2.2）。
///
/// 验证 NIMService.routers 数组按弱引用持有，业务方释放 router 后能自动清扫。
@MainActor
final class WeakRouterTests: XCTestCase {

    /// 强引用持有时，weak.router 不为 nil
    func test_strongOwnership_routerIsAlive() {
        let router = TestRouter()
        let wrap = WeakRouter(router)
        XCTAssertNotNil(wrap.router)
        XCTAssertTrue(wrap.isAlive)
        XCTAssertTrue(wrap.router === router)
    }

    /// 业务方释放强引用后，weak.router 立即变 nil
    func test_releaseStrongRef_routerBecomesNil() {
        var wrap: WeakRouter? = nil
        autoreleasepool {
            let router = TestRouter()
            wrap = WeakRouter(router)
            XCTAssertNotNil(wrap?.router)
        }
        // router 离开作用域后释放
        XCTAssertNil(wrap?.router)
        XCTAssertFalse(wrap?.isAlive ?? true)
    }

    /// 同一 router 多次包装出多个 WeakRouter，均指向同一对象
    func test_multipleWraps_sameRouterIdentity() {
        let router = TestRouter()
        let w1 = WeakRouter(router)
        let w2 = WeakRouter(router)
        XCTAssertTrue(w1.router === w2.router)
    }
}

/// 测试用 MessageRouter 实现：route 永远不消费，仅记录调用次数。
@MainActor
final class TestRouter: MessageRouter {
    private(set) var callCount = 0
    func route(_ attachType: AttachType,
               payload: [String: Any],
               context: MessageContext) -> Bool {
        callCount += 1
        return false
    }
}
