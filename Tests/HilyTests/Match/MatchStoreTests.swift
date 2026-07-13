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
/// | R21 | source != 'matchV4' → .matchingSuspended（v4 Gap-5）| `test_R21_nonMatchV4Source_matchingSuspended` |
/// | Gap-5a | suspended + 未接通 → 通话结束自动 openMatch | `test_Gap5a_suspended_notConnected_autoOpenMatch` |
///
@MainActor
final class MatchStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(service: FakeMatchService? = nil,
                           camera: FakeMatchCameraSession? = nil,
                           faceDetection: FakeFaceDetectionService? = nil,
                           preConfigure: (() -> Void)? = nil) -> (MatchStore, FakeMatchService, FakeMatchCameraSession) {
        // 清空 UserDefaults，然后 preConfigure（若需模拟冷启动 blocked / 首日已同意等）
        MatchPersistedStore.resetForTesting()
        preConfigure?()

        let fakeService = service ?? FakeMatchService()
        let fakeCamera = camera ?? FakeMatchCameraSession()
        let fakeFace = faceDetection ?? FakeFaceDetectionService()
        let store = MatchStore(service: fakeService, faceDetection: fakeFace)
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

    /// R21（v4 Gap-5 修订）：matching 中收 source != 'matchV4' → **`.matchingSuspended`**（非 .ended）。
    ///
    /// **对齐 H5 useCallApi.js:485-486 + c-goMatch.vue:130-135 MATCHING_LEFT 语义**：
    /// 关摄像头 + toggleMatch(0) 退池 + 保留"恢复"意图；通话结束时按 wasConnectedInCall 分流恢复。
    ///
    /// 历史：v3 spec §5.2 R21 原写"强制 .ended"，v4 追加 Gap-5 后语义变更为 .matchingSuspended，
    /// spec §2.2/§5.2 表格未同步；本 test 追随 impl 与 v4 Gap-5 描述对齐（2026-07-14）。
    func test_R21_nonMatchV4Source_matchingSuspended() async {
        let (store, service, camera) = makeStore()
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)
        await store.openMatch()
        store.handleCallStoreLeavingIdle()

        store.handleJoinCallSource("liveCall") // 非 matchV4

        XCTAssertEqual(store.state, .matchingSuspended,
                       "Gap-5：非 matchV4 → suspended（保留恢复意图，非 .ended）")
        // handleCallStoreLeavingIdle 已 stop 一次；handleJoinCallSource 非 matchV4 再 stop 一次
        XCTAssertGreaterThanOrEqual(camera.stopCallCount, 1, "摄像头应关（Gap-5 退池）")

        // 补发 toggleMatch(0) 是 fire-and-forget
        try? await Task.sleep(nanoseconds: 100_000_000)
        let closeCallCount = service.toggleMatchCalls.filter { $0.status == 0 }.count
        XCTAssertGreaterThanOrEqual(closeCallCount, 1,
                                    "non-matchV4 source should rollback server toggleMatch(0)")
    }

    /// R21b（v4 Gap-5 修订）：source=nil（joinCall 失败降级）→ 视同非 matchV4 → **`.matchingSuspended`**
    func test_R21b_nilSource_matchingSuspended() async {
        let (store, service, _) = makeStore()
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)
        await store.openMatch()
        store.handleCallStoreLeavingIdle()

        store.handleJoinCallSource(nil)

        XCTAssertEqual(store.state, .matchingSuspended,
                       "Gap-5：nil source 与非 matchV4 同款走 suspended")
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

    // MARK: - P1 · MATCHING_CALLING 内人脸检测（对齐 H5 c-goMatch.vue:110-119）

    /// P1-a：进入 .matchingCalling 时若立即检测无脸 → 触发 handleFaceCheckException（通话中路径）
    ///  - state 保持 .matchingCalling（CallStore 主控，不能被 MatchStore 抢改）
    ///  - isMatchBlocked = true 持久化
    ///  - toggleMatch(0, faceCheckStatus:1) 上报
    ///  - **不弹 showExitMatchPopup**（H5 line 279 明示仅 openMatch 期 5s 倒计时后才弹）
    func test_P1a_inCallingImmediateNoFace_keepStateBlockPersisted() async {
        let face = FakeFaceDetectionService()
        face.stubbedHasFace = true  // openMatch 阶段人脸正常
        let (store, service, _) = makeStore(faceDetection: face)
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)
        await store.openMatch()
        XCTAssertEqual(store.state, .matching)
        store.handleCallStoreLeavingIdle()

        // 命中 matchV4 前把 face 切成无脸 → 进入 matchingCalling 立即检测应触发异常
        face.stubbedHasFace = false
        store.handleJoinCallSource("matchV4")

        // state 应保持 .matchingCalling（不改）
        XCTAssertEqual(store.state, .matchingCalling)
        // isMatchBlocked 持久化
        XCTAssertTrue(store.isMatchBlocked)
        XCTAssertTrue(MatchPersistedStore.load().isMatchBlocked)
        // 不弹 exitMatchPopup
        XCTAssertFalse(store.showExitMatchPopup)

        // toggleMatch(0, faceCheckStatus:1) 是 fire-and-forget
        try? await Task.sleep(nanoseconds: 100_000_000)
        let faceFailCloseCount = service.toggleMatchCalls.filter { $0.status == 0 && $0.faceCheckStatus == 1 }.count
        XCTAssertEqual(faceFailCloseCount, 1, "in-call face fail must send toggleMatch(0, faceCheckStatus:1)")
    }

    /// P1-b：进入 .matchingCalling 立即检测有脸 → state 正常保持 .matchingCalling，isMatchBlocked 不变
    func test_P1b_inCallingImmediateHasFace_stateNormal() async {
        let face = FakeFaceDetectionService()
        face.stubbedHasFace = true
        let (store, service, _) = makeStore(faceDetection: face)
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)
        await store.openMatch()
        store.handleCallStoreLeavingIdle()

        store.handleJoinCallSource("matchV4")

        XCTAssertEqual(store.state, .matchingCalling)
        XCTAssertFalse(store.isMatchBlocked)
    }

    /// P1-c：通话中检测异常后通话结束 → handleCallStoreReturnedToIdle 判 isMatchBlocked → 转 .blocked（不 restart camera）
    func test_P1c_returnedToIdle_afterInCallBlocked_transitionsToBlocked() async {
        let face = FakeFaceDetectionService()
        let (store, service, camera) = makeStore(faceDetection: face)
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)
        await store.openMatch()
        store.handleCallStoreLeavingIdle()
        // 通话中检测异常
        face.stubbedHasFace = false
        store.handleJoinCallSource("matchV4")
        XCTAssertEqual(store.state, .matchingCalling)
        XCTAssertTrue(store.isMatchBlocked)
        let startCountBefore = camera.startCallCount

        // 通话结束
        store.handleCallStoreReturnedToIdle(lastJoinCallSource: "matchV4")

        XCTAssertEqual(store.state, .blocked, "in-call face fail + call end → .blocked, not .matching")
        XCTAssertEqual(camera.startCallCount, startCountBefore, "must NOT restart camera when blocked")
    }

    // MARK: - P2-1 · callError 通话异常关匹配（对齐 H5 useCallApi.js:397）

    /// P2-1-a：matchV4 通话异常出错结束 → state=.ended + toggleMatch(0) + camera.stop
    func test_P2_1a_matchV4_callError_forceEnded() async {
        let (store, service, camera) = makeStore()
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)
        await store.openMatch()
        store.handleCallStoreLeavingIdle()
        store.handleJoinCallSource("matchV4")
        XCTAssertEqual(store.state, .matchingCalling)
        let stopCountBefore = camera.stopCallCount
        let toggleCountBefore = service.toggleMatchCalls.filter { $0.status == 0 }.count

        // 模拟 CallStore 异常结束（callError 路径）
        store.handleCallStoreReturnedToIdle(lastJoinCallSource: "matchV4", lastCallError: true)

        XCTAssertEqual(store.state, .ended, "call error should force close match (align H5:397)")
        XCTAssertGreaterThan(camera.stopCallCount, stopCountBefore, "camera should stop on call error")

        try? await Task.sleep(nanoseconds: 100_000_000)
        let toggleCountAfter = service.toggleMatchCalls.filter { $0.status == 0 }.count
        XCTAssertGreaterThan(toggleCountAfter, toggleCountBefore, "should send toggleMatch(0) on call error")
    }

    /// P2-1-b：matchV4 通话正常结束（无 error）→ 回 .matching + restart camera（现有行为不受影响）
    func test_P2_1b_matchV4_normalEnd_backwardCompatibility() async {
        let (store, service, camera) = makeStore()
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)
        await store.openMatch()
        store.handleCallStoreLeavingIdle()
        store.handleJoinCallSource("matchV4")
        let startCountBefore = camera.startCallCount

        // 正常结束（lastCallError = false / 默认值）
        store.handleCallStoreReturnedToIdle(lastJoinCallSource: "matchV4")

        XCTAssertEqual(store.state, .matching, "normal end should resume matching")
        XCTAssertGreaterThan(camera.startCallCount, startCountBefore, "camera should restart on normal end")
    }

    // MARK: - Gap-5 · .matchingSuspended 出口边分流（wasConnectedInCall 判定）

    /// Gap-5-a：suspended + 用户未接通（`wasConnectedInCall=false`，默认值）→ 通话结束自动 openMatch。
    ///
    /// 对齐 [MatchStore.swift](Sources/Match/MatchStore.swift) `handleCallStoreReturnedToIdle` 的
    /// `.matchingSuspended` 分支：接通过弹 Resume Alert；未接通 → `Task { await self.openMatch() }`。
    ///
    /// 覆盖场景：主播 .matching 时收到非 matchV4 来电，用户直接拒绝/未接通，通话结束 → 自动恢复匹配。
    ///
    /// **未覆盖**（需 test-only bridge mock 基建，见交付说明）：Gap-5-b `wasConnectedInCall=true`
    /// → 弹 Resume Match Alert 分支。
    func test_Gap5a_suspended_notConnected_autoOpenMatch() async {
        let (store, service, _) = makeStore()
        service.isMatchOpenResult = .success(.allowed)
        service.toggleMatchResult = .success(true)
        await store.openMatch()
        store.handleCallStoreLeavingIdle()
        store.handleJoinCallSource("liveCall")
        XCTAssertEqual(store.state, .matchingSuspended)
        let isMatchOpenCountBefore = service.isMatchOpenCallCount

        // 通话结束（未接通 —— wasConnectedInCall 保持默认 false）
        store.handleCallStoreReturnedToIdle(lastJoinCallSource: "liveCall")

        // handleCallStoreReturnedToIdle 内 Task { openMatch } 是异步的，等其调度完成
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(store.state, .matching, "Gap-5-a: not-connected → auto openMatch resumes matching")
        XCTAssertFalse(store.showResumeMatchAlert, "not-connected 路径不应弹 Resume Alert")
        // openMatch 内部会再次调 isMatchOpen（自动恢复走完整校验流程）
        XCTAssertGreaterThan(service.isMatchOpenCallCount, isMatchOpenCountBefore,
                             "auto openMatch should run isOpen check")
    }
}
