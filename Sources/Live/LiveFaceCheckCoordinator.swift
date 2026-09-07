import Foundation
import QuartzCore

struct LiveFaceRuntimeState: Equatable, Sendable {
    var isLiving = false
    var isBeautyEnabled = false
    var isBeautyCameraActive = false
    var isInOneToOneCall = false
    var isLiveEnding = false
}
typealias LiveFaceCheckRuntimeState = LiveFaceRuntimeState

enum LiveFaceCheckEvent: Equatable, Sendable { case showReminder, closeReminder, restarted, fixedNoFace, autoStop }

/// 纯业务状态机。所有时间均为单调时钟秒数，由调用方提供。
final class LiveFaceCheckCoordinator {
    let config: LiveAnchorFaceCheckConfig
    private(set) var lastFaceAt: TimeInterval?
    private(set) var nextFixedReport: TimeInterval = 0
    private(set) var noFaceObserved = false
    private(set) var reminderShown = false
    private(set) var paused = true
    private(set) var stopped = false
    private var started = false

    init(config: LiveAnchorFaceCheckConfig) { self.config = config }
    func start(startedAtMonotonic: TimeInterval) { started = true; resume(startedAtMonotonic) }
    func pause(reason: String? = nil) { guard !stopped else { return }; paused = true; lastFaceAt = nil; noFaceObserved = false; reminderShown = false }
    func pause() { pause(reason: nil) }
    func resume(_ now: TimeInterval) { guard !stopped else { return }; paused = true; lastFaceAt = nil; nextFixedReport = now + 20; noFaceObserved = false; reminderShown = false }
    func stop() { stopped = true; paused = true; lastFaceAt = nil }

    func onLiveTick(now: TimeInterval, runtime: LiveFaceRuntimeState, latest: FaceDetectionResult?) -> [LiveFaceCheckEvent] {
        guard started, !stopped else { return [] }
        let validRuntime = runtime.isLiving && runtime.isBeautyEnabled && runtime.isBeautyCameraActive && !runtime.isInOneToOneCall && !runtime.isLiveEnding
        guard validRuntime, let result = latest, now - result.detectedAt <= 2, now >= result.detectedAt else {
            let shouldClose = reminderShown
            pause()
            return shouldClose ? [.closeReminder] : []
        }
        if paused { paused = false; lastFaceAt = now; nextFixedReport = now + 20; noFaceObserved = false; reminderShown = false }
        var events: [LiveFaceCheckEvent] = []
        if result.hasFace {
            if noFaceObserved { events.append(.restarted) }
            if reminderShown { events.append(.closeReminder) }
            lastFaceAt = now; nextFixedReport = now + 20; noFaceObserved = false; reminderShown = false
            return events
        }
        noFaceObserved = true
        let sinceFace = now - (lastFaceAt ?? now)
        if now >= nextFixedReport { events.append(.fixedNoFace); nextFixedReport = now + 20 }
        if config.autoStopDuration > 0 && sinceFace >= Double(config.autoStopDuration) { stopped = true; paused = true; events.append(.autoStop); return events }
        if config.remindDuration > 0 && sinceFace >= Double(config.remindDuration) && !reminderShown { reminderShown = true; events.append(.showReminder) }
        return events
    }
}

enum MonotonicClock { static var now: TimeInterval { CACurrentMediaTime() } }
