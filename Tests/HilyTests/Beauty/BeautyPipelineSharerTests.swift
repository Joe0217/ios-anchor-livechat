import XCTest
import Combine

/// K spec §5.2 R6/R10-b/R11/R16：BeautyPipelineSharer setup 状态机 + subscriber 栈 + pending 队列 + 中断态。
@MainActor
final class BeautyPipelineSharerTests: XCTestCase {

    // MARK: - Helpers

    private func makeSharer() -> BeautyPipelineSharer {
        // 独立 Sharer 实例（不用 .shared 单例），注入 fake persistence
        BeautyPipelineSharer(persistence: FakeBeautyPersistence())
    }

    // MARK: - Setup 状态机（红队 A3）

    func test_initialState_notStarted() {
        let s = makeSharer()
        XCTAssertEqual(s.setupState, .notStarted)
    }

    func test_startSetup_transitionsToInProgress() {
        let s = makeSharer()
        s.startSetupIfNeeded()
        XCTAssertEqual(s.setupState, .inProgress)
    }

    func test_startSetup_idempotent_whileInProgress() {
        let s = makeSharer()
        s.startSetupIfNeeded()
        s.startSetupIfNeeded()  // 第二次调用应 no-op
        XCTAssertEqual(s.setupState, .inProgress)
    }

    func test_reportSetupResult_success_transitionsToReady() {
        let s = makeSharer()
        s.startSetupIfNeeded()
        s.reportSetupResult(.success(()))
        XCTAssertEqual(s.setupState, .ready)
    }

    func test_reportSetupResult_failure_transitionsToFailed() {
        let s = makeSharer()
        s.startSetupIfNeeded()
        s.reportSetupResult(.failure(.bundleMissing))
        XCTAssertEqual(s.setupState, .failed(.bundleMissing))
    }

    /// 失败后再触发 setup 应可重试
    func test_startSetup_afterFailure_canRestart() {
        let s = makeSharer()
        s.startSetupIfNeeded()
        s.reportSetupResult(.failure(.genericSetupFailed))
        s.startSetupIfNeeded()
        XCTAssertEqual(s.setupState, .inProgress)
    }

    // MARK: - Subscriber 优先级栈（红队 B1）

    func test_attach_singleRenderer() {
        let s = makeSharer()
        let r = MockBeautyRenderer(label: "live")
        s.attach(r, token: .live)
        XCTAssertEqual(s.testSubscriberCount, 1)
        XCTAssertTrue(s.testTopRenderer === r)
    }

    func test_attach_sameInstance_replacesInsteadOfDuplicate() {
        let s = makeSharer()
        let r = MockBeautyRenderer(label: "live")
        s.attach(r, token: .live)
        s.attach(r, token: .call)  // 同实例，不同 token
        XCTAssertEqual(s.testSubscriberCount, 1, "同实例应替换而非重复入栈")
    }

    /// 栈顶按 token 优先级选（live > call > party > preview）
    func test_topRenderer_byTokenPriority() {
        let s = makeSharer()
        let preview = MockBeautyRenderer(label: "preview")
        let party = MockBeautyRenderer(label: "party")
        let call = MockBeautyRenderer(label: "call")
        let live = MockBeautyRenderer(label: "live")

        s.attach(preview, token: .preview)
        XCTAssertTrue(s.testTopRenderer === preview)

        s.attach(party, token: .party)
        XCTAssertTrue(s.testTopRenderer === party, "party 优先级 > preview")

        s.attach(call, token: .call)
        XCTAssertTrue(s.testTopRenderer === call, "call 优先级 > party")

        s.attach(live, token: .live)
        XCTAssertTrue(s.testTopRenderer === live, "live 优先级最高")
    }

    /// 高优先级 renderer detach 后，栈顶回落到次高
    func test_detach_topPrio_fallsBackToNext() {
        let s = makeSharer()
        let live = MockBeautyRenderer(label: "live")
        let call = MockBeautyRenderer(label: "call")

        s.attach(call, token: .call)
        s.attach(live, token: .live)
        XCTAssertTrue(s.testTopRenderer === live)

        s.detach(live)
        XCTAssertTrue(s.testTopRenderer === call, "live detach 后回落到 call")
    }

    func test_detach_nonexistent_noOp() {
        let s = makeSharer()
        let r = MockBeautyRenderer(label: "orphan")
        s.detach(r)  // 未 attach 的 renderer，detach 应 no-op 不 crash
        XCTAssertEqual(s.testSubscriberCount, 0)
    }

    // MARK: - Store 变化广播

    /// setup ready 时，Store mutate → 栈顶 renderer 收到 apply
    func test_storeChange_readyState_appliesToTop() async {
        let s = makeSharer()
        s.testForceSetupState(.ready)
        let r = MockBeautyRenderer(label: "live")
        s.attach(r, token: .live)  // ready + 新栈顶 → attach 时立即 apply 一次
        let baseline = r.applyCalls.count

        s.store.mutate { $0.blur = 88 }
        await Task.yield()
        XCTAssertEqual(r.applyCalls.count, baseline + 1, "store 变化后应新增一次 apply")
        XCTAssertEqual(r.applyCalls.last?.blur, 88)
    }

    /// setup 未 ready 时，Store 变化缓冲到 pending
    func test_storeChange_notStarted_buffersPending() async {
        let s = makeSharer()
        let r = MockBeautyRenderer(label: "live")
        s.attach(r, token: .live)

        s.store.mutate { $0.blur = 66 }
        await Task.yield()
        XCTAssertEqual(r.applyCalls.count, 0, "notStarted 状态不广播")
        XCTAssertNotNil(s.testPendingSettings)
        XCTAssertEqual(s.testPendingSettings?.blur, 66)
    }

    /// setup 就绪后 replay pending（红队 D1）
    func test_reportSetupResult_success_replaysPending() async {
        let s = makeSharer()
        let r = MockBeautyRenderer(label: "live")
        s.attach(r, token: .live)

        s.store.mutate { $0.blur = 66 }
        await Task.yield()
        XCTAssertEqual(r.applyCalls.count, 0)

        s.startSetupIfNeeded()
        s.reportSetupResult(.success(()))
        XCTAssertEqual(r.applyCalls.count, 1)
        XCTAssertEqual(r.applyCalls.last?.blur, 66)
        XCTAssertNil(s.testPendingSettings, "replay 后 pending 清空")
    }

    /// failed 态下 Store 变化不 apply 也不缓冲（Store 层自持数据）
    func test_storeChange_failedState_neitherAppliesNorPending() async {
        let s = makeSharer()
        s.testForceSetupState(.failed(.bundleMissing))
        let r = MockBeautyRenderer(label: "preview")
        s.attach(r, token: .preview)

        s.store.mutate { $0.blur = 44 }
        await Task.yield()
        XCTAssertEqual(r.applyCalls.count, 0)
    }

    // MARK: - 中断态（红队 F4，R16）

    func test_interrupted_blocksApply() async {
        let s = makeSharer()
        s.testForceSetupState(.ready)
        let r = MockBeautyRenderer(label: "live")
        s.attach(r, token: .live)  // attach 时立即 apply 一次
        let baseline = r.applyCalls.count
        s.setInterrupted(true)

        s.store.mutate { $0.blur = 77 }
        await Task.yield()
        XCTAssertEqual(r.applyCalls.count, baseline, "中断期间不新增 apply")
    }

    /// 中断结束后 replay
    func test_interruptionEnded_replaysToTop() async {
        let s = makeSharer()
        s.testForceSetupState(.ready)
        let r = MockBeautyRenderer(label: "live")
        s.attach(r, token: .live)  // attach 时立即 apply 一次
        let baseline = r.applyCalls.count
        s.setInterrupted(true)

        s.store.mutate { $0.blur = 77 }
        await Task.yield()
        XCTAssertEqual(r.applyCalls.count, baseline, "中断期不 apply")

        s.setInterrupted(false)  // 中断结束
        XCTAssertEqual(r.applyCalls.count, baseline + 1, "中断结束应 replay 当前 store")
        XCTAssertEqual(r.applyCalls.last?.blur, 77)
    }

    // MARK: - R10-b: attach 新栈顶时 apply 立即到位

    func test_attachNewTop_immediatelyAppliesCurrentSettings() {
        let s = makeSharer()
        s.testForceSetupState(.ready)
        s.store.mutate { $0.whiten = 82 }

        let r = MockBeautyRenderer(label: "call")
        s.attach(r, token: .call)
        XCTAssertEqual(r.applyCalls.count, 1, "新栈顶 attach 应立即 apply 当前 store")
        XCTAssertEqual(r.applyCalls.last?.whiten, 82)
    }
}
