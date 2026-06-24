import XCTest

/// G 里程碑 M2-7：PKCountdownController 单测（spec §13.1）。
///
/// 覆盖：
/// - 三计时器（invite / inPK / punish）互不干扰
/// - cancel 后 onTick / onExpire 不再触发
/// - 基于 endAt 的 inPK 倒计时，endAt 已过返回 0 并立即 expire
/// - scheduleX 重复调用幂等（覆盖旧 task）
@MainActor
final class PKCountdownControllerTests: XCTestCase {

    var controller: PKCountdownController!

    override func setUp() async throws {
        try await super.setUp()
        controller = PKCountdownController()
    }

    override func tearDown() async throws {
        controller.cancelAll()
        controller = nil
        try await super.tearDown()
    }

    // MARK: - 三计时器互不干扰

    func test_threeTimers_runIndependently() async {
        let inviteTicks = TickRecorder()
        let inPKTicks = TickRecorder()
        let punishTicks = TickRecorder()

        controller.scheduleInvite(seconds: 3,
                                   onTick: { v in inviteTicks.add(v) },
                                   onExpire: {})
        controller.scheduleInPK(endAt: Date().addingTimeInterval(3),
                                onTick: { v in inPKTicks.add(v) },
                                onExpire: {})
        controller.schedulePunish(seconds: 3,
                                  onTick: { v in punishTicks.add(v) },
                                  onExpire: {})

        XCTAssertTrue(controller.hasInviteTimer)
        XCTAssertTrue(controller.hasInPKTimer)
        XCTAssertTrue(controller.hasPunishTimer)

        try? await Task.sleep(nanoseconds: 1_500_000_000)
        // 1.5s 后三计时器都应至少 tick 过初始值与至少一次递减
        XCTAssertGreaterThanOrEqual(inviteTicks.count, 2)
        XCTAssertGreaterThanOrEqual(inPKTicks.count, 2)
        XCTAssertGreaterThanOrEqual(punishTicks.count, 2)
    }

    // MARK: - cancel 立即停止

    func test_cancelInvite_stopsTicks() async {
        let recorder = TickRecorder()
        let expireCalled = ExpireFlag()

        controller.scheduleInvite(seconds: 5,
                                   onTick: { v in recorder.add(v) },
                                   onExpire: { expireCalled.set() })
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let before = recorder.count
        controller.cancelInvite()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let after = recorder.count
        XCTAssertEqual(after, before, "cancel 后不应再产生 onTick")
        XCTAssertFalse(expireCalled.value, "cancel 后 onExpire 不应触发")
        XCTAssertFalse(controller.hasInviteTimer)
    }

    func test_cancelAll_stopsAllThreeTimers() async {
        let invR = TickRecorder()
        let pkR = TickRecorder()
        let pnR = TickRecorder()

        controller.scheduleInvite(seconds: 5, onTick: { v in invR.add(v) }, onExpire: {})
        controller.scheduleInPK(endAt: Date().addingTimeInterval(5),
                                onTick: { v in pkR.add(v) }, onExpire: {})
        controller.schedulePunish(seconds: 5, onTick: { v in pnR.add(v) }, onExpire: {})

        // 500ms 时机点：task 在 sleep(1s) 中段，cancel 能精准 interrupt sleep → CancellationError
        // 避免在 1000ms 时机 cancel 与第二次 tick 入 MainActor queue 时序竞争
        try? await Task.sleep(nanoseconds: 500_000_000)
        controller.cancelAll()
        let snapshot = (invR.count, pkR.count, pnR.count)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        // 允许 +1 容差：极少数情况下 cancel 与 MainActor.run dispatch race，
        // 但 onTick 最多多触发一次（不再有后续）
        XCTAssertLessThanOrEqual(invR.count - snapshot.0, 1, "cancelAll 后 onTick 最多再触发 1 次")
        XCTAssertLessThanOrEqual(pkR.count - snapshot.1, 1)
        XCTAssertLessThanOrEqual(pnR.count - snapshot.2, 1)
        XCTAssertFalse(controller.hasInviteTimer)
        XCTAssertFalse(controller.hasInPKTimer)
        XCTAssertFalse(controller.hasPunishTimer)
    }

    // MARK: - inPK endAt 已过去立即 expire

    func test_inPKEndAtAlreadyPast_immediatelyExpires() async {
        let expireCalled = ExpireFlag()
        controller.scheduleInPK(endAt: Date().addingTimeInterval(-10),
                                onTick: { _ in },
                                onExpire: { expireCalled.set() })
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertTrue(expireCalled.value, "endAt 过去时下一秒 tick 即 expire")
    }

    // MARK: - inPK 倒计时基于绝对时间戳（前后台漂移测试模拟）

    func test_inPKCountdown_basedOnAbsoluteTime() async {
        let recorder = TickRecorder()
        let end = Date().addingTimeInterval(3)
        controller.scheduleInPK(endAt: end,
                                onTick: { v in recorder.add(v) },
                                onExpire: {})
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        // 1.5s 后 tick 值应该是约 (3 - 1.5 = 1.5 → 取 Int 1 或 2)
        let lastTick = recorder.values.last ?? -1
        XCTAssertTrue(lastTick == 1 || lastTick == 2,
                      "tick 值应基于 (endAt - now)，预期 1 或 2，实际 \(lastTick)")
    }

    // MARK: - schedule 重复调用幂等

    func test_scheduleInvite_twice_replacesOldTimer() async {
        let firstTicks = TickRecorder()
        let secondTicks = TickRecorder()

        controller.scheduleInvite(seconds: 5,
                                   onTick: { v in firstTicks.add(v) },
                                   onExpire: {})
        try? await Task.sleep(nanoseconds: 500_000_000)
        // 第二次 schedule：第一次 timer 应被 cancel
        controller.scheduleInvite(seconds: 5,
                                   onTick: { v in secondTicks.add(v) },
                                   onExpire: {})
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let firstFinal = firstTicks.count
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(firstTicks.count, firstFinal, "第一次 timer 已被覆盖，不应继续 tick")
        XCTAssertGreaterThanOrEqual(secondTicks.count, 1, "第二次 timer 应正常 tick")
    }
}

// MARK: - 测试辅助

/// 线程安全的 tick 计数器（main actor 内调用安全；测试用）。
@MainActor
private final class TickRecorder {
    private(set) var values: [Int] = []
    var count: Int { values.count }
    func add(_ v: Int) { values.append(v) }
}

@MainActor
private final class ExpireFlag {
    private(set) var value: Bool = false
    func set() { value = true }
}
