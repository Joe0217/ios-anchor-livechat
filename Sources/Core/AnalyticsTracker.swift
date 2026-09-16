import Foundation
import UIKit
import ThinkingSDK

/// 数数 ThinkingData 的唯一接入点。
///
/// 未配置本机 xcconfig 时静默停用，不影响业务链路。默认事件即时 flush；RTC/IM 高频的
/// Party 事件通过 `PartyAnalytics` 改用 SDK 批量发送。
enum AnalyticsTracker {
    static func operation<T>(_ name: String, scene: String, properties: [String: Any], perform: () async throws -> T) async rethrows -> T {
        trackAgora(name + "_request", scene: scene, properties: properties)
        do {
            let result = try await perform()
            trackAgora(name + "_success", scene: scene, properties: properties)
            return result
        } catch {
            var failure = properties
            failure["error_code"] = (error as? APIError)?.code ?? String((error as NSError).code)
            trackAgora(name + "_failed", scene: scene, properties: failure)
            throw error
        }
    }
    private static let lock = NSLock()
    private static var started = false
    @MainActor private static var connections: [String: (state: Int, reason: Int)] = [:]
    static func trackAgora(_ name: String, scene: String, properties: [String: Any] = [:]) {
        var p = properties
        p["scene"] = scene
        p["_include_network"] = true
        let snapshot = p
        DispatchQueue.main.async {
            var enriched = snapshot
            if name == "agora_connection_state", let stateNumber = snapshot["state"] as? NSNumber {
                let state = stateNumber.intValue
                let key = scene + ":" + (snapshot["channel_id"] as? String ?? "")
                let previous = connections[key]
                let reason = (snapshot["reason"] as? NSNumber)?.intValue ?? -1
                if previous?.state == state && previous?.reason == reason { return }
                connections[key] = (state, reason)
                enriched["connection_status"] = state == 4 ? "reconnecting" : state == 5 ? (previous?.state == 4 ? "reconnect_failed" : "failed") : state == 1 ? "disconnected" : state == 3 ? (previous?.state == 4 ? "reconnected" : "connected") : "connecting"
                if state == 1 || state == 5 { connections.removeValue(forKey: key) }
            }
            trackBehavior(name, properties: enriched, immediately: false)
        }
    }
    static func trackAgoraStart(_ scene: String, properties: [String: Any] = [:]) { trackAgora("agora_start", scene: scene, properties: properties) }
    @MainActor private static let networkMonitor = SystemNetworkMonitor()
    @MainActor static func trackAppLifecycle(_ name: String) {
        var p = networkProperties()
        p["behavior_name"] = name
        if name == "app_launch" {
            p["app_version"] = AppConfig.appVersion
            p["app_build"] = AppConfig.buildVersion
        }
        track("hifunny_log", properties: p)
    }

    @MainActor private static func networkProperties() -> [String: Any] {
        ["network_type": networkMonitor.currentNetworkType,
         "network_signal": networkMonitor.currentNetworkType == "cellular" ? networkMonitor.currentRadioTech : "unknown"]
    }

    static func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        guard let config = AppConfig.thinkingDataConfiguration else {
            return
        }

        TDAnalytics.start(withAppId: config.appId, serverUrl: config.serverURL)
        TDAnalytics.setSuperProperties(["#app_version": AppConfig.appVersion])
        started = true
        // `start()` owns `lock`; calling the public `track()` here would re-enter
        // `start()` and deadlock on the non-recursive NSLock during app launch.
        TDAnalytics.track("hifunny_log", properties: ["app_name": "HillyFun"])
        TDAnalytics.flush()
    }

    static func login(userId: Int?) {
        guard let userId, userId > 0 else { return }
        start()
        guard isStarted else { return }
        TDAnalytics.login(String(userId))
    }

    static func logout() {
        guard isStarted else { return }
        TDAnalytics.flush()
        TDAnalytics.logout()
    }

    static func track(_ event: String,
                      properties: [String: Any] = [:],
                      immediately: Bool = true) {
        start()
        guard isStarted else {
            return
        }
        var normalizedProperties = properties
        let normalizedEvent = event == "c_log" ? "hifunny_log" : event
        if event == "c_log" {
            normalizedProperties.removeValue(forKey: "type")
        }
        if normalizedEvent == "hifunny_log" {
            normalizedProperties["app_name"] = "HillyFun"
            if normalizedProperties.removeValue(forKey: "_include_network") != nil {
                let snapshot = normalizedProperties
                DispatchQueue.main.async {
                    var enriched = snapshot
                    enriched.merge(networkProperties()) { current, _ in current }
                    track(normalizedEvent, properties: enriched, immediately: immediately)
                }
                return
            }
        }
        TDAnalytics.track(normalizedEvent, properties: normalizedProperties)
        let mirrorsToBehavior = normalizedEvent == "partyRoom_enter"
            || normalizedEvent.hasPrefix("h_party_video_")
            || normalizedEvent.hasPrefix("h_party_voice_")
            || normalizedEvent == "h_party_room_leave"
        if mirrorsToBehavior {
            var behaviorProperties = normalizedProperties
            behaviorProperties["behavior_name"] = normalizedEvent
            behaviorProperties["app_name"] = "HillyFun"
            TDAnalytics.track("hifunny_log", properties: behaviorProperties)
        }
        if immediately {
            TDAnalytics.flush()
        }
    }

    /// 产品行为埋点：ThinkingData 事件名固定为 hifunny_log。
    /// `behavior_name` 保存具体行为，避免与历史业务事件名混淆。
    static func trackBehavior(_ behaviorName: String,
                              properties: [String: Any] = [:],
                              immediately: Bool = true) {
        var enriched = properties
        enriched["behavior_name"] = behaviorName
        if enriched["model"] == nil {
            enriched["model"] = SessionStore.effectiveUserTypeSnapshot ?? 107
        }
        track("hifunny_log", properties: enriched, immediately: immediately)
    }

    private static var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }
}

/// Party 房埋点的轻量入口。
///
/// Party 房内有 RTC、IM 和礼物等高频链路，不能因单次用户操作立即 flush 造成额外网络工作。
/// ThinkingData SDK 自行批量持久化和发送；该封装只用于明确的用户动作或已发生的业务结果，且永不参与业务分支。
enum PartyAnalytics {
    static func track(_ event: String, properties: [String: Any] = [:]) {
        var enriched = properties
        if enriched["moduleType"] == nil {
            enriched["moduleType"] = "party"
        }
        AnalyticsTracker.track(event, properties: enriched, immediately: false)
    }

    static func roomProperties(
        roomId: String?,
        ownerId: String?,
        roomTempId: String? = nil
    ) -> [String: Any] {
        var properties: [String: Any] = [:]
        if let roomId, !roomId.isEmpty {
            // H5 同时保留两个历史字段，数据平台依赖这两个字段做跨端聚合。
            properties["roomid"] = roomId
            properties["room_id"] = roomId
        }
        if let ownerId, !ownerId.isEmpty {
            properties["roomHost_id"] = ownerId
        }
        if let roomTempId, !roomTempId.isEmpty {
            properties["modeNum"] = roomTempId
        }
        return properties
    }
}

/// Business sampling only; never runs face detection or controls media resources.
@MainActor
enum FaceBusinessAnalytics {
    private static var sources: [String: () -> [String: Any]] = [:]
    private static var task: Task<Void, Never>?

    static func update(_ scene: String, active: Bool, properties: @escaping () -> [String: Any]) {
        sources[scene] = active ? properties : nil
        if sources.isEmpty {
            task?.cancel()
            task = nil
        } else if task == nil {
            task = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                    guard !Task.isCancelled else { return }
                    guard UIApplication.shared.applicationState == .active else { continue }
                    // A private call suspends the room's video pipeline.
                    let selected = sources["call"] != nil ? ["call"] : Array(sources.keys)
                    for scene in selected {
                        guard let source = sources[scene] else { continue }
                        var p = source()
                        p["scene"] = p["scene"] ?? scene
                        let result = LatestFaceDetectionAdapter.analytics.latestResult
                        let fresh = result.map { ProcessInfo.processInfo.systemUptime - $0.detectedAt < 3 } ?? false
                        p["face_status"] = fresh ? (result?.hasFace == true ? "face" : "no_face") : "unknown"
                        p["_include_network"] = true
                        AnalyticsTracker.trackBehavior("face_check", properties: p, immediately: false)
                    }
                }
            }
        }
    }
}
