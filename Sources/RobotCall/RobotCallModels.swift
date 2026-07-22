import Foundation

/// NIM attachType=133 的机器人来电载荷。
///
/// 服务端字段沿用 H5 `fakeUserCallInfo`：`id`、`recordId`、`fileUrl`、
/// `agoraChannelId`、`autoHangupTime`。ID 和时长兼容 String / Number 两种形态。
struct RobotCallInvite: Equatable {
    let videoId: String
    let recordId: String
    let fileURL: URL
    let agoraChannelId: String?
    let autoHangupSeconds: Int
    let displayUserId: String
    /// SDK 注入的服务端通知时间。缺失时保留兼容路径，由状态机按实时消息处理。
    let notificationTimestamp: Date?

    init?(payload: [String: Any]) {
        guard let videoId = RobotCallPayload.string(payload["id"] ?? payload["videoId"]),
              let recordId = RobotCallPayload.string(payload["recordId"]),
              let fileURLText = RobotCallPayload.string(payload["fileUrl"] ?? payload["fileURL"]),
              let fileURL = URL(string: fileURLText),
              let scheme = fileURL.scheme?.lowercased(),
              scheme == "https",
              let host = fileURL.host,
              !host.isEmpty else {
            return nil
        }

        self.videoId = videoId
        self.recordId = recordId
        self.fileURL = fileURL
        self.agoraChannelId = RobotCallPayload.string(payload["agoraChannelId"])
        self.autoHangupSeconds = max(1, RobotCallPayload.int(payload["autoHangupTime"]) ?? 30)
        self.displayUserId = RobotCallPayload.string(payload["userId"] ?? payload["virtualUserId"]) ?? videoId
        self.notificationTimestamp = RobotCallPayload.timestamp(payload["_nimCustomNotificationTimestamp"])
    }

    /// NIM 登录后会补发离线系统消息。来电超过响铃窗口后不应重新打开相机或推流。
    func isFresh(now: Date, maximumAge: TimeInterval, maximumFutureSkew: TimeInterval) -> Bool {
        guard let notificationTimestamp else { return true }
        let age = now.timeIntervalSince(notificationTimestamp)
        return age >= -maximumFutureSkew && age <= maximumAge
    }
}

/// NIM attachType=132 的结算通知。
struct RobotCallReward: Equatable {
    let recordId: String
    let videoId: String?
    let isEligible: Bool
    let diamondText: String
    let callDurationSeconds: Int

    init?(payload: [String: Any]) {
        guard let recordId = RobotCallPayload.string(payload["recordId"]) else { return nil }

        self.recordId = recordId
        self.videoId = RobotCallPayload.string(payload["videoId"] ?? payload["id"])
        self.isEligible = RobotCallPayload.bool(payload["type"])
        self.diamondText = RobotCallPayload.string(payload["content"] ?? payload["diamondNum"]) ?? "0"
        self.callDurationSeconds = max(0, RobotCallPayload.int(payload["callTime"] ?? payload["duration"]) ?? 0)
    }
}

enum RobotCallState: Equatable {
    case idle
    case ringing
    case connecting
    case connected
}

/// 机器人通话与真人通话共用进程级 Agora 引擎，不能并行进入 RTC。
enum RobotCallAdmission {
    static func blocksOtherCalls(state: RobotCallState, hasVisibleReward: Bool) -> Bool {
        state != .idle || hasVisibleReward
    }
}

enum RobotCallEndReason: Equatable {
    case rejected
    case ringingTimeout
    case manualHangup
    case autoHangup
    case videoFinished
    case acceptFailed
}

enum RobotCallPayload {
    static func string(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? NSNumber, !isBool(value) {
            return value.stringValue
        }
        if let value = value as? Int { return String(value) }
        if let value = value as? Int64 { return String(value) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let value = value as? NSNumber, !isBool(value) { return value.intValue }
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber, !isBool(value) { return value.intValue != 0 }
        if let value = value as? Int { return value != 0 }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes": return true
            default: return false
            }
        }
        return false
    }

    static func timestamp(_ value: Any?) -> Date? {
        let raw: Double?
        if let value = value as? NSNumber, !isBool(value) {
            raw = value.doubleValue
        } else if let value = value as? Double {
            raw = value
        } else if let value = value as? Int {
            raw = Double(value)
        } else if let value = value as? String {
            raw = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            raw = nil
        }
        guard let raw, raw.isFinite, raw > 0 else { return nil }
        // NIM uses seconds; accept millisecond-form SDK bridges defensively.
        let seconds = raw > 100_000_000_000 ? raw / 1_000 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        let type = String(cString: number.objCType)
        return type == "c" || type == "B"
    }
}
