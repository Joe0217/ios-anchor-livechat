import Foundation

/// 派对房主播周任务响应。安卓 `WeekTaskDialog` 以 offset 分页拉取上麦时长奖励任务。
///
/// 服务端尚未提供 DTO；这里用 JSON 结构化解析兼容 Android/H5 常见字段名，并在首次真机请求时
/// 记录解密后的字段名（private）供后续将 alias 收敛到实际契约。
struct PartyWeeklyTaskPage: Equatable {
    let tasks: [PartyWeeklyTask]
    let nextOffset: String?
    let total: Int?

    static func decode(from data: Data) throws -> PartyWeeklyTaskPage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PartyWeeklyTaskDecodeError.invalidRoot
        }

        // PartyAPIClient normally unwraps `result`, but a few party endpoints return an
        // additional business `data` wrapper. Keep the pagination metadata in the same layer.
        let payload = unwrappedPayload(from: object)
        let rawTasks = firstArray(in: payload, keys: ["list", "records", "items", "rows", "content", "taskList", "tasks", "taskVos"])
        let tasks = rawTasks.compactMap { PartyWeeklyTask(dictionary: $0) }
        let nextOffset = firstString(in: payload, keys: ["nextOffset", "offset", "cursor"])
        let total = firstInt(in: payload, keys: ["total", "totalCount", "count"])
        return PartyWeeklyTaskPage(tasks: tasks, nextOffset: nextOffset, total: total)
    }

    static func unwrappedPayload(from object: [String: Any]) -> [String: Any] {
        var payload = object
        // Limit the unwrap depth so an unrelated nested task field can never replace the page.
        for _ in 0..<2 {
            guard let wrapped = firstObject(in: payload, keys: ["data", "result"]) else { break }
            payload = wrapped
        }
        return payload
    }

    static func firstArray(in object: [String: Any], keys: [String]) -> [[String: Any]] {
        for key in keys {
            if let items = object[key] as? [[String: Any]] { return items }
            if let items = object[key] as? [Any] {
                let dictionaries = items.compactMap { $0 as? [String: Any] }
                if !dictionaries.isEmpty { return dictionaries }
            }
        }
        return []
    }

    static func firstObject(in object: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = object[key] as? [String: Any] { return value }
            if let raw = object[key] as? String,
               let data = raw.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return value
            }
        }
        return nil
    }

    static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let value = object[key] as? Int64 { return String(value) }
            if let value = object[key] as? Int { return String(value) }
        }
        return nil
    }

    static func firstInt(in object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? Int { return value }
            if let value = object[key] as? Int64 { return Int(exactly: value) }
            if let value = object[key] as? Double { return Int(value) }
            if let value = object[key] as? String, let parsed = Int(value) { return parsed }
        }
        return nil
    }
}

enum PartyWeeklyTaskDecodeError: Error {
    case invalidRoot
}

/// 热门房任务的接口字段尚未有 Android DTO；只解析已验证的状态/展示字段，原始响应仅在 DEBUG 记录。
struct PartyHotRoomTaskStatus: Equatable {
    /// 是否处于热榜 TopX。与是否存在任务分开，非热门房引导依赖此状态。
    let isTopRoom: Bool
    let isActive: Bool
    /// 非热门房时服务端下发的行为路径，例如 `top_room_guide`。
    let path: String?
    let title: String
    let current: Int?
    let target: Int?

    static func decode(from data: Data) throws -> PartyHotRoomTaskStatus {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PartyWeeklyTaskDecodeError.invalidRoot
        }
        let payload = PartyWeeklyTaskPage.unwrappedPayload(from: root)
        let task = PartyWeeklyTaskPage.firstObject(in: payload, keys: ["taskInfo", "task", "mission", "taskData"]) ?? payload
        let hot = firstBool(in: payload, keys: ["isTop3", "isTopX", "isHot3", "isHot", "isHotRoom", "isExistHot3", "isExistTop3", "existHot3", "topX"])
            ?? firstBool(in: task, keys: ["isTop3", "isTopX", "isHot3", "isHot", "isHotRoom", "isExistHot3", "isExistTop3", "existHot3", "topX"])
            ?? false
        let path = PartyWeeklyTaskPage.firstString(in: payload, keys: ["path", "route", "action"])
        let title = PartyWeeklyTaskPage.firstString(in: task, keys: ["taskName", "taskTitle", "title", "name", "taskDesc", "description"]) ?? ""
        let current = PartyWeeklyTaskPage.firstInt(in: task, keys: ["progress", "current", "currentValue", "completedValue", "accumulatedDuration", "liveTime"])
        let target = PartyWeeklyTaskPage.firstInt(in: task, keys: ["target", "targetValue", "needDuration", "targetDuration", "totalDuration", "duration"])
        let hasTaskDetails = !title.isEmpty || current != nil || target != nil || task["screenFaceLimit"] != nil
        // Android 仅在“在榜且有任务”时提示；单独的 TopX 状态不能误展示 Mission。
        return PartyHotRoomTaskStatus(
            isTopRoom: hot,
            isActive: hot && hasTaskDetails,
            path: path,
            title: title,
            current: current,
            target: target
        )
    }

    var fraction: Double? {
        guard let current, let target, target > 0 else { return nil }
        return min(1, max(0, Double(current) / Double(target)))
    }

    private static func firstBool(in object: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = object[key] as? Bool { return value }
            if let value = object[key] as? Int { return value != 0 }
            if let value = object[key] as? String {
                if ["1", "true", "yes"].contains(value.lowercased()) { return true }
                if ["0", "false", "no"].contains(value.lowercased()) { return false }
            }
        }
        return nil
    }
}

/// `top/availableSeat` 返回的可跳转热门房。当前只依赖接口文档确认的 roomId，其他字段仅用于展示。
struct PartyHotRoomGuide: Identifiable, Equatable {
    let roomId: String
    let roomName: String

    var id: String { roomId }

    static func decode(from data: Data) throws -> PartyHotRoomGuide? {
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw != "null", !raw.isEmpty,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let payload = PartyWeeklyTaskPage.unwrappedPayload(from: object)
        guard let roomId = PartyWeeklyTaskPage.firstString(in: payload, keys: ["roomId", "id"]), !roomId.isEmpty else {
            return nil
        }
        let roomName = PartyWeeklyTaskPage.firstString(in: payload, keys: ["roomName", "name", "title"]) ?? ""
        return PartyHotRoomGuide(roomId: roomId, roomName: roomName)
    }
}

/// 一档上麦时长奖励。后端字段名以 Android `WeekTaskInfo` 真机响应为准；下列候选只做兼容读取。
struct PartyWeeklyTask: Identifiable, Equatable {
    let id: String
    let title: String
    let targetLiveTime: Int?
    let progressLiveTime: Int?
    let rewards: [PartyWeeklyTaskReward]

    init?(dictionary: [String: Any]) {
        let title = PartyWeeklyTaskPage.firstString(
            in: dictionary,
            keys: ["taskName", "taskTitle", "title", "name", "description", "taskDesc"]
        ) ?? ""
        let targetLiveTime = PartyWeeklyTaskPage.firstInt(
            in: dictionary,
            keys: ["targetLiveTime", "targetTime", "targetDuration", "needLiveTime", "duration", "target"]
        )
        let progressLiveTime = PartyWeeklyTaskPage.firstInt(
            in: dictionary,
            keys: ["liveTime", "accumulatedDuration", "progressLiveTime", "progress", "currentTime"]
        )

        // Android's DTO is not available in this workspace. Preserve visible task rows if the
        // backend omits an explicit id, while still giving SwiftUI a stable pagination key.
        let id = PartyWeeklyTaskPage.firstString(
            in: dictionary,
            keys: ["taskId", "id", "taskCode", "taskType"]
        ) ?? "weekly-task-\(targetLiveTime ?? 0)-\(title)"
        guard id != "weekly-task-0-" else { return nil }

        self.id = id
        self.title = title
        self.targetLiveTime = targetLiveTime
        self.progressLiveTime = progressLiveTime

        let rewardDictionaries = PartyWeeklyTaskPage.firstArray(
            in: dictionary,
            keys: ["rewards", "rewardList", "rewardItems", "awardList"]
        )
        if !rewardDictionaries.isEmpty {
            rewards = rewardDictionaries.compactMap(PartyWeeklyTaskReward.init(dictionary:))
        } else if let reward = PartyWeeklyTaskPage.firstObject(
            in: dictionary,
            keys: ["reward", "rewardInfo", "award"]
        ), let value = PartyWeeklyTaskReward(dictionary: reward) {
            rewards = [value]
        } else if let reward = PartyWeeklyTaskReward(dictionary: dictionary) {
            rewards = [reward]
        } else {
            rewards = []
        }
    }
}

/// 1023 以及周任务列表共用的奖励项。数量保留为 String，避免 gems 以 Long 下发时发生精度损失。
struct PartyWeeklyTaskReward: Identifiable, Equatable {
    let id: String
    let name: String
    let amount: String?

    init?(dictionary: [String: Any]) {
        let name = PartyWeeklyTaskPage.firstString(
            in: dictionary,
            keys: ["rewardName", "name", "rewardType", "rewardTitle"]
        )
        let amount = PartyWeeklyTaskPage.firstString(
            in: dictionary,
            keys: ["gems", "coins", "amount", "rewardAmount", "rewardValue", "value", "reward"]
        )
        guard name != nil || amount != nil else { return nil }
        self.name = name ?? ""
        self.amount = amount
        id = "\(self.name)-\(amount ?? "")"
    }
}

extension PartyWeeklyTaskReward {
    var compactText: String {
        let value = amount ?? ""
        switch (name.isEmpty, value.isEmpty) {
        case (true, true): return ""
        case (true, false): return "+\(value)"
        case (false, true): return name
        case (false, false): return "+\(value) \(name)"
        }
    }
}

/// P2P `attachType=1023` 奖励通知。安卓先播放麦位奖励特效，再展示此奖励列表。
struct PartyWeeklyTaskRewardNotification: Identifiable, Equatable {
    let id = UUID()
    let liveTime: Int
    let rewards: [PartyWeeklyTaskReward]

    init?(payload: [String: Any]) {
        let liveTime = PartyWeeklyTaskPage.firstInt(in: payload, keys: ["liveTime", "accumulatedDuration"]) ?? 0
        let rewards = PartyWeeklyTaskPage.firstArray(
            in: payload,
            keys: ["rewards", "rewardList", "rewardItems", "awardList"]
        ).compactMap(PartyWeeklyTaskReward.init(dictionary:))
        guard !rewards.isEmpty else { return nil }
        self.liveTime = liveTime
        self.rewards = rewards
    }
}
