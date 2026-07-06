import Combine
import XCTest

/// L 里程碑 Match — MatchStore 状态机单测。
///
/// 覆盖 `docs/plan/L-spec-视频匹配Match-*.md` §5.1 F 序列 + §5.2 R 序列中 store 层可测试项。
/// UI 层 case（跑马灯 3s / CGoMatchButton 视觉 / 防抖 / 弹窗倒计时）留 step 1b 落地。
///
/// **F/R 序列 → 测试方法对应表**（step 1a 验收门必查）：
///
/// | # | 场景 | Test method |
/// |---|---|---|
/// | F1  | 冷启动 unblocked → .ended                | `test_F1_coldStart_unblocked_stateEnded` |
/// | F2  | 冷启动 blocked=true → .blocked           | `test_F2_coldStart_blocked_stateBlocked` |
/// | F3  | openMatch happy → .matching + camera on  | `test_F3_openMatch_happy_stateMatching` |
/// | F4  | closeMatch → .ended + toggleMatch(0)     | `test_F4_closeMatch_stateEnded` |
/// | F5  | 非今日首次（ruleAgreedDate=今天）         | `test_F5_notFirstToday_isFirstMatchTodayFalse` |
/// | F9  | source='matchV4' → .matchingCalling      | `test_F9_joinCallSourceMatchV4_stateMatchingCalling` |
/// | F10 | CallStore ended && source='matchV4' → .matching restart | `test_F10_callEnded_matchV4_stateMatchingResume` |
/// | F14 | .blocked → isOpen(1) → 清 blocked → .matching | `test_F14_blocked_openReturns1_clearsAndMatching` |
/// | R1  | isOpen returns .faceCheckFailed → .blocked  | `test_R1_isOpenFace_stateBlocked_persisted` |
/// | R2  | isOpen returns .exceededCount → .blocked     | `test_R2_isOpenExceed_stateBlocked` |
/// | R3  | isOpen throws → 保持 .ended                  | `test_R3_isOpenNetworkFail_keepEnded` |
/// | R4  | toggleMatch returns false → 保持 .ended     | `test_R4_toggleMatchFail_keepEnded` |
/// | R6  | handleCameraStartTimeout → .ended + toggle(0) | `test_R6_cameraStartTimeout_rollback` |
/// | R9  | handleCameraInterruptionTimeout → .ended     | `test_R9_cameraInterruptionTimeout_stateEnded` |
/// | R10 | handleIMOffline → .ended（不调 toggleMatch）  | `test_R10_imOffline_stateEnded_noToggleMatch` |
/// | R19 | shouldShowTipPopup 组合态 gate               | `test_R19_shouldShowTipPopup_combinedGate` |
/// | R21 | source != 'matchV4' → .ended + toggle(0)     | `test_R21_nonMatchV4Source_forceEnded` |
///
@MainActor
final class MatchStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(service: FakeMatchService? = nil,
                           camera: FakeMatchCameraSession? = nil,
                           preConfigure: (() -> Void)? = nil) -> (MatchStore, FakeMatchService, FakeMatchCameraSession) {
        // 清空 UserDefaults，然后 preConfigure（若需模拟冷启动 blocked / 首日已同意等）
        MatchPersistedStore.resetForTesting()
        preConfigure?()

        let fakeService = service ?? FakeMatchService()
        let fakeCamera = camera ?? FakeMatchCameraSession()
        let store = MatchStore(service: fakeService)
        store.attachCameraSession(fakeCamera)
        return (store, fakeService, fakeCamera)
    }

    override func setUp() {
        super.setUp()
        MatchPersistedStore.resetForTesting()
    }

    override func tearDown() {
        MatchPersistedStore.resetForTesting()
        super.tearDown()
    }

    // MARK: - F 序列（正向）

    /// F1：冷启动 UserDefaults 无 blocked → state=.ended
    func test_F1_coldStart_unblocked_stateEnded() {
        let (store, _, _) = makeStore()
        XCTAssertEqual(store.state, .ended)
        XCTAssertFalse(store.isMatchBlocked)
    }

    /// F2：冷启动 UserDefaults isMatchBlocked=true → state=.blocked（v3 §2.3 不变量）
    func test_F2_coldStart_blocked_stateBlocked() {
        let (store, _, _) = makeStore(preConfigure: {
            MatchPersistedStore.saveIsMatchBlocked(true)
        })
        XCTAssertEqual(store.state, .blocked)
        XCTAssertTrue(store.isMatchBlocked)
    }

    /// F3：openMatch happy path → isOpen(1) → toggleMatch(1) → camera.start() → state=.matching
    /// v3 修正：删除 beauty pre-check，先切态后开相机
    func test_F3_openMatch_happy_stateMatching() async {
        let (store, service, camera) = makeStore()
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)

        await store.openMatch()

        XCTAssertEqual(store.state, .matching)
        XCTAssertEqual(service.isMatchOpenCallCount, 1)
        XCTAssertEqual(service.toggleMatchCalls.count, 1)
        XCTAssertEqual(service.toggleMatchCalls.first?.status, 1)
        XCTAssertNil(service.toggleMatchCalls.first?.faceCheckStatus)
        XCTAssertEqual(camera.startCallCount, 1)
        XCTAssertTrue(camera.isRunning)
    }

    /// F4：closeMatch → toggleMatch(0) → camera.stop() → state=.ended
    func test_F4_closeMatch_stateEnded() async {
        let (store, service, camera) = makeStore()
        // 先进入 .matching
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)
        await store.openMatch()
        XCTAssertEqual(store.state, .matching)

        await store.closeMatch()

        XCTAssertEqual(store.state, .ended)
        XCTAssertEqual(camera.stopCallCount, 1)
        XCTAssertFalse(camera.isRunning)

        // toggleMatch(0) 是 fire-and-forget Task，需要 yield 让其调度
        try? await Task.sleep(nanoseconds: 100_000_000)
        let hasClose = service.toggleMatchCalls.contains { $0.status == 0 }
        XCTAssertTrue(hasClose, "closeMatch should trigger toggleMatch(0) fire-and-forget")
    }

    /// F5：非今日首次（UserDefaults.ruleAgreedDate = 今天）→ isFirstMatchToday=false
    func test_F5_notFirstToday_isFirstMatchTodayFalse() {
        let today = MatchDateHelper.todayString()
        let (store, _, _) = makeStore(preConfigure: {
            MatchPersistedStore.saveRuleAgreedDate(today)
        })
        XCTAssertFalse(store.isFirstMatchToday)
    }

    /// F9：matching 中收 source='matchV4' → state=.matchingCalling
    func test_F9_joinCallSourceMatchV4_stateMatchingCalling() async {
        let (store, service, _) = makeStore()
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)
        await store.openMatch()
        XCTAssertEqual(store.state, .matching)

        // 模拟命中链路：CallStore.state → .connecting（触发 unsubscribe）→ source='matchV4' 到达
        store.handleCallStoreLeavingIdle()
        store.handleJoinCallSource("matchV4")

        XCTAssertEqual(store.state, .matchingCalling)
    }

    /// F10：matchingCalling → CallStore returned to idle && lastSource='matchV4' → .matching + camera restart
    func test_F10_callEnded_matchV4_stateMatchingResume() async {
        let (store, service, camera) = makeStore()
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)
        await store.openMatch()
        store.handleCallStoreLeavingIdle()
        store.handleJoinCallSource("matchV4")
        XCTAssertEqual(store.state, .matchingCalling)
        let startCountBefore = camera.startCallCount

        store.handleCallStoreReturnedToIdle(lastJoinCallSource: "matchV4")

        XCTAssertEqual(store.state, .matching)
        XCTAssertGreaterThan(camera.startCallCount, startCountBefore, "camera should restart on match resume")
    }

    /// F14：.blocked 态点开启 → isOpen 返 1 → 清 isMatchBlocked → 进入 openMatch 流程 → .matching
    func test_F14_blocked_openReturns1_clearsAndMatching() async {
        let (store, service, _) = makeStore(preConfigure: {
            MatchPersistedStore.saveIsMatchBlocked(true)
        })
        XCTAssertEqual(store.state, .blocked)
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)

        await store.openMatch()

        XCTAssertEqual(store.state, .matching)
        XCTAssertFalse(store.isMatchBlocked)
        XCTAssertFalse(MatchPersistedStore.load().isMatchBlocked, "UserDefaults should be cleared")
    }

    // MARK: - R 序列（反向 / 边界）

    /// R1：isOpen 返 .faceCheckFailed → state=.blocked + isMatchBlocked=true UserDefaults 持久化
    func test_R1_isOpenFace_stateBlocked_persisted() async {
        let (store, service, camera) = makeStore()
        service.isMatchOpenResult = .success(.faceCheckFailed)

        await store.openMatch()

        XCTAssertEqual(store.state, .blocked)
        XCTAssertTrue(store.isMatchBlocked)
        XCTAssertTrue(MatchPersistedStore.load().isMatchBlocked, "isMatchBlocked must persist")
        XCTAssertEqual(service.toggleMatchCalls.count, 0, "isOpen 拒绝后**不应**发起 toggleMatch")
        XCTAssertEqual(camera.startCallCount, 0)
    }

    /// R2：isOpen 返 .exceededCount → state=.blocked
    func test_R2_isOpenExceed_stateBlocked() async {
        let (store, service, _) = makeStore()
        service.isMatchOpenResult = .success(.exceededCount)

        await store.openMatch()

        XCTAssertEqual(store.state, .blocked)
        XCTAssertTrue(store.isMatchBlocked)
        XCTAssertEqual(service.toggleMatchCalls.count, 0)
    }

    /// R3：isOpen 网络失败 → 保持 .ended，isMatchBlocked 不变
    func test_R3_isOpenNetworkFail_keepEnded() async {
        let (store, service, _) = makeStore()
        service.isMatchOpenResult = .failure(TestError.offline)

        await store.openMatch()

        XCTAssertEqual(store.state, .ended)
        XCTAssertFalse(store.isMatchBlocked)
        XCTAssertEqual(service.toggleMatchCalls.count, 0)
    }

    /// R4：toggleMatch 返 false or 抛异常 → state=.ended（不进 .matching）
    func test_R4_toggleMatchFail_keepEnded() async {
        let (store, service, camera) = makeStore()
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(false)

        await store.openMatch()

        XCTAssertEqual(store.state, .ended)
        XCTAssertEqual(camera.startCallCount, 0)
    }

    /// R4b：toggleMatch 抛异常 → state=.ended
    func test_R4b_toggleMatchThrows_keepEnded() async {
        let (store, service, camera) = makeStore()
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .failure(TestError.offline)

        await store.openMatch()

        XCTAssertEqual(store.state, .ended)
        XCTAssertEqual(camera.startCallCount, 0)
    }

    /// R6：cameraSession 3s 超时 → handleCameraStartTimeout → state=.ended + camera.stop + toggleMatch(0) 回滚
    func test_R6_cameraStartTimeout_rollback() async {
        let (store, service, camera) = makeStore()
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)
        await store.openMatch()
        XCTAssertEqual(store.state, .matching)
        service.toggleMatchResult = .success(true) // 补发 toggleMatch(0) 也 success

        store.handleCameraStartTimeout()

        XCTAssertEqual(store.state, .ended)
        XCTAssertEqual(camera.stopCallCount, 1)

        // 等 fire-and-forget toggleMatch(0) 完成
        try? await Task.sleep(nanoseconds: 100_000_000)
        let closeCallCount = service.toggleMatchCalls.filter { $0.status == 0 }.count
        XCTAssertEqual(closeCallCount, 1, "should fire toggleMatch(0) to rollback server")
    }

    /// R9：cameraSession interruption >= 30s → handleCameraInterruptionTimeout → state=.ended
    func test_R9_cameraInterruptionTimeout_stateEnded() async {
        let (store, service, camera) = makeStore()
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)
        await store.openMatch()

        store.handleCameraInterruptionTimeout()

        XCTAssertEqual(store.state, .ended)
        XCTAssertEqual(camera.stopCallCount, 1)
    }

    /// R10：IM 掉线 → handleIMOffline → state=.ended，**不调 toggleMatch**（网络不可达）
    func test_R10_imOffline_stateEnded_noToggleMatch() async {
        let (store, service, camera) = makeStore()
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)
        await store.openMatch()
        XCTAssertEqual(store.state, .matching)
        let toggleCallsBefore = service.toggleMatchCalls.count

        store.handleIMOffline()

        XCTAssertEqual(store.state, .ended)
        XCTAssertEqual(camera.stopCallCount, 1)
        // 关键不变量：IM 掉线**不发起** toggleMatch（对齐 v3 §2.2）
        XCTAssertEqual(service.toggleMatchCalls.count, toggleCallsBefore,
                       "IM offline path must NOT call toggleMatch (network unreachable)")
    }

    /// R19：shouldShowTipPopup 组合态 gate 覆盖
    func test_R19_shouldShowTipPopup_combinedGate() async {
        let (store, service, _) = makeStore()

        // 组合 1：state=.ended && !isMatchBlocked && !noReminderChecked && !appHidden → true
        XCTAssertTrue(store.shouldShowTipPopup(appHidden: false))

        // 组合 2：appHidden=true → false
        XCTAssertFalse(store.shouldShowTipPopup(appHidden: true))

        // 组合 3：state=.matching → false（v3 §5.2 R19 只在 .ended 才弹）
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)
        await store.openMatch()
        XCTAssertEqual(store.state, .matching)
        XCTAssertFalse(store.shouldShowTipPopup(appHidden: false))

        // 组合 4：state=.blocked → false
        await store.closeMatch()
        MatchPersistedStore.saveIsMatchBlocked(true)
        let (blockedStore, _, _) = makeStore(preConfigure: {
            MatchPersistedStore.saveIsMatchBlocked(true)
        })
        XCTAssertFalse(blockedStore.shouldShowTipPopup(appHidden: false))
    }

    /// R21：matching 中收 source != 'matchV4' → 强制关匹配 + camera stop + toggleMatch(0)
    func test_R21_nonMatchV4Source_forceEnded() async {
        let (store, service, camera) = makeStore()
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)
        await store.openMatch()
        store.handleCallStoreLeavingIdle()

        store.handleJoinCallSource("liveCall") // 非 matchV4

        XCTAssertEqual(store.state, .ended)
        // handleCallStoreLeavingIdle 已 stop 一次；handleJoinCallSource 非 matchV4 再 stop 一次
        XCTAssertGreaterThanOrEqual(camera.stopCallCount, 1)

        // 补发 toggleMatch(0) 是 fire-and-forget
        try? await Task.sleep(nanoseconds: 100_000_000)
        let closeCallCount = service.toggleMatchCalls.filter { $0.status == 0 }.count
        XCTAssertGreaterThanOrEqual(closeCallCount, 1, "non-matchV4 source should rollback server toggleMatch(0)")
    }

    /// R21b：source=nil（joinCall 失败降级）→ 视为非 matchV4 → force .ended
    func test_R21b_nilSource_forceEnded() async {
        let (store, service, _) = makeStore()
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)
        await store.openMatch()
        store.handleCallStoreLeavingIdle()

        store.handleJoinCallSource(nil)

        XCTAssertEqual(store.state, .ended)
    }

    // MARK: - 补充：不变量 / 边界

    /// 不变量：openMatch 在 .matching / .matchingCalling 期间应该 no-op（防误调）
    func test_openMatch_noop_when_matching() async {
        let (store, service, _) = makeStore()
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)
        await store.openMatch()
        XCTAssertEqual(store.state, .matching)
        let openCallsBefore = service.isMatchOpenCallCount

        await store.openMatch() // 重复调

        XCTAssertEqual(service.isMatchOpenCallCount, openCallsBefore, "second openMatch should be no-op in .matching")
    }

    /// 不变量：closeMatch 在 .ended 期间应该 no-op
    func test_closeMatch_noop_when_ended() async {
        let (store, service, _) = makeStore()
        XCTAssertEqual(store.state, .ended)

        await store.closeMatch()

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(service.toggleMatchCalls.count, 0, "closeMatch in .ended should NOT call toggleMatch")
    }

    /// 不变量：markTodayNoReminder → 持久化 + 立即 published 生效
    func test_markTodayNoReminder_persists() async {
        let (store, _, _) = makeStore()
        XCTAssertFalse(store.todayNoReminderChecked)

        store.markTodayNoReminder()

        XCTAssertTrue(store.todayNoReminderChecked)
        XCTAssertTrue(MatchPersistedStore.load().todayNoReminderChecked)
    }
}
