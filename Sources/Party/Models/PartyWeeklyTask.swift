import Foundation

/// Party 房 Weekly Task：宝石目标进度与礼物流水。与热门房麦时任务是两套独立模型。
struct PartyWeeklyTaskPage: Equatable {
    let targetValue: Int
    let currentProgress: Int
    let giftHistory: [PartyGiftHistory]
    let nextOffset: Int64?

    static func decode(from data: Data) throws -> PartyWeeklyTaskPage {
        if String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
            return PartyWeeklyTaskPage(targetValue: 0, currentProgress: 0, giftHistory: [], nextOffset: nil)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PartyWeeklyTaskDecodeError.invalidRoot
        }
        let payload = unwrappedPayload(from: root)
        let history = firstArray(in: payload, keys: ["giftHistory", "list", "records", "items"])
            .compactMap(PartyGiftHistory.init(dictionary:))
        let target = firstInt(in: payload, keys: ["targetValue"]) ?? 0
        let progress = firstInt(in: payload, keys: ["currentProgress"]) ?? 0
        // Android 以最后一条礼物的 createTime 作为下一页 offset。
        let nextOffset = firstInt64(in: payload, keys: ["nextOffset", "offset", "cursor"])
            ?? history.last?.createTime
        return PartyWeeklyTaskPage(
            targetValue: target,
            currentProgress: progress,
            giftHistory: history,
            nextOffset: nextOffset
        )
    }

    static func unwrappedPayload(from object: [String: Any]) -> [String: Any] {
        var payload = object
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
            if let value = object[key] as? Double { return String(value) }
        }
        return nil
    }

    static func firstInt(in object: [String: Any], keys: [String]) -> Int? {
        firstInt64(in: object, keys: keys).flatMap(Int.init(exactly:))
    }

    static func firstInt64(in object: [String: Any], keys: [String]) -> Int64? {
        for key in keys {
            if let value = object[key] as? Int64 { return value }
            if let value = object[key] as? Int { return Int64(value) }
            if let value = object[key] as? Double { return Int64(value) }
            if let value = object[key] as? String, let parsed = Int64(value) { return parsed }
        }
        return nil
    }
}

enum PartyWeeklyTaskDecodeError: Error {
    case invalidRoot
}

struct PartyGiftHistory: Identifiable, Equatable {
    let sendUserId: String
    let giftId: String
    let giftPrice: Int
    let num: Int
    let giftPercent: String?
    let createTime: Int64
    let nickname: String
    let avatar: String?
    let giftIcon: String?

    var id: String { "\(sendUserId)-\(giftId)-\(createTime)" }
    var gemValue: Int { max(0, giftPrice) * max(0, num) }

    init?(dictionary: [String: Any]) {
        guard let createTime = PartyWeeklyTaskPage.firstInt64(in: dictionary, keys: ["createTime"]) else { return nil }
        self.sendUserId = PartyWeeklyTaskPage.firstString(in: dictionary, keys: ["sendUserId", "userId"]) ?? ""
        self.giftId = PartyWeeklyTaskPage.firstString(in: dictionary, keys: ["giftId", "id"]) ?? ""
        self.giftPrice = PartyWeeklyTaskPage.firstInt(in: dictionary, keys: ["giftPrice"]) ?? 0
        self.num = PartyWeeklyTaskPage.firstInt(in: dictionary, keys: ["num", "giftNum"]) ?? 0
        self.giftPercent = PartyWeeklyTaskPage.firstString(in: dictionary, keys: ["giftPercent"])
        self.createTime = createTime
        self.nickname = PartyWeeklyTaskPage.firstString(in: dictionary, keys: ["nickname", "nickName"]) ?? ""
        self.avatar = PartyWeeklyTaskPage.firstString(in: dictionary, keys: ["avatar", "avatarUrl"])
        self.giftIcon = PartyWeeklyTaskPage.firstString(in: dictionary, keys: ["giftIcon", "giftImg", "giftSmallImg"])
    }
}

/// TopX 热门房任务。安卓 `TaskInfo` 的字段名和语义由任务整理文档明确。
struct PartyHotRoomTaskStatus: Equatable {
    let existHot: Bool
    let liveValue: Int
    let nowFaceErrorCount: Int
    let screenFaceLimit: Int
    let anchorTasks: [PartyAnchorTask]
    /// 服务端历史来源字段，仅保留解码兼容和调试；掉榜引导的产品门控由本地路由来源决定。
    let path: String?

    var isTopRoom: Bool { existHot }
    var isActive: Bool { existHot && !anchorTasks.isEmpty }
    var finalLiveTime: Int? { anchorTasks.last?.liveTime }
    /// 所有档位均已完成后不再进行人脸检测或上报。
    var isCompleted: Bool {
        guard let finalLiveTime else { return false }
        return liveValue >= finalLiveTime
    }
    var currentTask: PartyAnchorTask? {
        guard !anchorTasks.isEmpty else { return nil }
        return anchorTasks.first(where: { liveValue < $0.liveTime }) ?? anchorTasks.last
    }
    var topProgress: PartyHotTaskProgress? {
        guard let task = currentTask else { return nil }
        return PartyHotTaskProgress(
            current: min(max(0, liveValue), task.liveTime),
            target: task.liveTime,
            rewardText: "+\(task.rewardValue)"
        )
    }

    static func decode(from data: Data) throws -> PartyHotRoomTaskStatus {
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
            return PartyHotRoomTaskStatus(
                existHot: false,
                liveValue: 0,
                nowFaceErrorCount: 0,
                screenFaceLimit: 0,
                anchorTasks: [],
                path: nil
            )
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PartyWeeklyTaskDecodeError.invalidRoot
        }
        let payload = PartyWeeklyTaskPage.unwrappedPayload(from: root)
        let tasks = PartyWeeklyTaskPage.firstArray(in: payload, keys: ["anchorTasks"])
            .compactMap(PartyAnchorTask.init(dictionary:))
            .sorted { $0.liveTime < $1.liveTime }
        return PartyHotRoomTaskStatus(
            existHot: firstBool(in: payload, keys: ["existHot"]) ?? false,
            liveValue: PartyWeeklyTaskPage.firstInt(in: payload, keys: ["liveValue"]) ?? 0,
            nowFaceErrorCount: PartyWeeklyTaskPage.firstInt(in: payload, keys: ["nowFaceErrorCount"]) ?? 0,
            screenFaceLimit: PartyWeeklyTaskPage.firstInt(in: payload, keys: ["screenFaceLimit"]) ?? 0,
            anchorTasks: tasks,
            path: PartyWeeklyTaskPage.firstString(in: payload, keys: ["path"])
        )
    }

    func updating(liveValue: Int) -> PartyHotRoomTaskStatus {
        PartyHotRoomTaskStatus(
            existHot: existHot,
            liveValue: max(self.liveValue, liveValue),
            nowFaceErrorCount: nowFaceErrorCount,
            screenFaceLimit: screenFaceLimit,
            anchorTasks: anchorTasks,
            path: path
        )
    }

    static func firstBool(in object: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = object[key] as? Bool { return value }
            if let value = object[key] as? Int { return value != 0 }
            if let value = object[key] as? String {
                if ["1", "true"].contains(value.lowercased()) { return true }
                if ["0", "false"].contains(value.lowercased()) { return false }
            }
        }
        return nil
    }

}

struct PartyAnchorTask: Identifiable, Equatable {
    let id: String
    let liveTime: Int
    let rewardValue: String
    let rewardType: Int?
    let rewardName: String?
    let effectiveHours: Int?
    let extendJson: String?
    let rewardAsset: PartyHotTaskRewardAsset?

    var rewardText: String {
        if let rewardName, !rewardName.isEmpty { return "+\(rewardValue) \(rewardName)" }
        return "+\(rewardValue)"
    }

    init?(dictionary: [String: Any]) {
        guard let liveTime = PartyWeeklyTaskPage.firstInt(in: dictionary, keys: ["liveTime"]), liveTime > 0 else { return nil }
        self.id = PartyWeeklyTaskPage.firstString(in: dictionary, keys: ["id"]) ?? "anchor-task-\(liveTime)"
        self.liveTime = liveTime
        self.rewardValue = PartyWeeklyTaskPage.firstString(in: dictionary, keys: ["rewardValue"]) ?? "0"
        self.rewardType = PartyWeeklyTaskPage.firstInt(in: dictionary, keys: ["rewardType"])
        self.rewardName = PartyWeeklyTaskPage.firstString(in: dictionary, keys: ["rewardName"])
        self.effectiveHours = PartyWeeklyTaskPage.firstInt(in: dictionary, keys: ["effectiveHours"])
        self.extendJson = PartyWeeklyTaskPage.firstString(in: dictionary, keys: ["extendJson"])
        self.rewardAsset = PartyHotTaskRewardAsset.decode(from: dictionary, key: "extendJson")
    }
}

struct PartyHotTaskProgress: Equatable {
    let current: Int
    let target: Int
    let rewardText: String

    var remaining: Int { max(0, target - current) }
    var fraction: Double { min(1, max(0, Double(current) / Double(max(target, 1)))) }
}

/// `top/availableSeat` 返回的可跳转热门房。
struct PartyHotRoomGuide: Identifiable, Equatable {
    let roomId: String
    let roomName: String
    let rank: Int?
    let hasSeat: Bool
    /// `top/availableSeat` 部分网关会直接带目标房锁房状态；缺失时由大厅列表二次确认。
    let isPasswordProtected: Bool?
    let rewards: [PartyHotTaskRewardConfig]

    var id: String { roomId }

    static func decode(from data: Data) throws -> PartyHotRoomGuide? {
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw != "null", !raw.isEmpty,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let payload = PartyWeeklyTaskPage.unwrappedPayload(from: object)
        // Android 的跳转参数语义是 targetRoomId；部分网关版本返回 roomId / partyRoomId。
        // 泛化的 `id` 未被接口契约确认是业务 roomId，不能用于跳房。
        guard let roomId = PartyWeeklyTaskPage.firstString(
            in: payload,
            keys: ["targetRoomId", "roomId", "partyRoomId"]
        ), !roomId.isEmpty else {
            return nil
        }
        let targetRoom = PartyWeeklyTaskPage.firstObject(
            in: payload,
            keys: ["targetRoom", "room", "roomInfo"]
        )
        let roomMetadata = targetRoom ?? payload
        let lockFlag = PartyWeeklyTaskPage.firstInt(in: roomMetadata, keys: ["lockFlag", "lock"])
            ?? PartyWeeklyTaskPage.firstInt(in: payload, keys: ["lockFlag", "lock"])
        let needsPassword = PartyHotRoomTaskStatus.firstBool(
            in: roomMetadata,
            keys: ["needPassword", "isPasswordRoom", "hasPassword"]
        ) ?? PartyHotRoomTaskStatus.firstBool(
            in: payload,
            keys: ["needPassword", "isPasswordRoom", "hasPassword"]
        )
        let isPasswordProtected: Bool? = lockFlag == nil && needsPassword == nil
            ? nil
            : lockFlag == 1 || needsPassword == true
        let roomName = PartyWeeklyTaskPage.firstString(in: roomMetadata, keys: ["roomName", "name", "title"])
            ?? PartyWeeklyTaskPage.firstString(in: payload, keys: ["roomName", "name", "title"])
            ?? ""
        return PartyHotRoomGuide(
            roomId: roomId,
            roomName: roomName,
            rank: PartyWeeklyTaskPage.firstInt(in: payload, keys: ["rank"]),
            // 接口语义是“有空位的热门房”。旧网关未返回该字段时保持可跳转，避免误阻断有效入口。
            hasSeat: PartyHotRoomTaskStatus.firstBool(in: payload, keys: ["hasSeat", "hasAvailableSeat"]) ?? true,
            isPasswordProtected: isPasswordProtected,
            rewards: PartyWeeklyTaskPage.firstArray(in: payload, keys: ["rewards", "anchorTasks"])
                .compactMap(PartyHotTaskRewardConfig.init(dictionary:))
        )
    }
}

/// `top/availableSeat` 引导卡片的服务端奖励配置。
struct PartyHotTaskRewardConfig: Identifiable, Equatable {
    let rewardType: Int?
    let rewardName: String
    let iconURL: String?

    var id: String { [String(rewardType ?? -1), rewardName, iconURL ?? ""].joined(separator: "-") }

    init?(dictionary: [String: Any]) {
        let rewardName = PartyWeeklyTaskPage.firstString(in: dictionary, keys: ["rewardName", "name"]) ?? ""
        let rewardType = PartyWeeklyTaskPage.firstInt(in: dictionary, keys: ["rewardType"])
        let iconURL = PartyWeeklyTaskPage.firstString(in: dictionary, keys: ["icon", "iconUrl", "itemSmallImg"])
        guard rewardType != nil || !rewardName.isEmpty || iconURL != nil else { return nil }
        self.rewardType = rewardType
        self.rewardName = rewardName
        self.iconURL = iconURL
    }
}

/// 热门任务 `extendJson` 中的图片与特效资源。服务端可能下发对象或 JSON 字符串。
struct PartyHotTaskRewardAsset: Equatable {
    let iconURL: String?
    let vfxURL: String?

    static func decode(from dictionary: [String: Any], key: String) -> PartyHotTaskRewardAsset? {
        if let object = PartyWeeklyTaskPage.firstObject(in: dictionary, keys: [key]) {
            return PartyHotTaskRewardAsset(dictionary: object)
        }
        guard let raw = PartyWeeklyTaskPage.firstString(in: dictionary, keys: [key]),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return PartyHotTaskRewardAsset(dictionary: object)
    }

    private init?(dictionary: [String: Any]) {
        let iconURL = PartyWeeklyTaskPage.firstString(in: dictionary, keys: ["icon", "iconUrl", "imageUrl"])
        let vfxURL = PartyWeeklyTaskPage.firstString(in: dictionary, keys: ["vfxUrl", "vfxURL", "effectUrl"])
        guard iconURL != nil || vfxURL != nil else { return nil }
        self.iconURL = iconURL
        self.vfxURL = vfxURL
    }
}

/// 1023 热门麦时任务奖励通知。安卓先播宝石效果，后展示达标领奖弹窗。
struct PartyHotTaskRewardNotification: Identifiable, Equatable {
    let id = UUID()
    let liveTime: Int
    let rewards: [PartyHotTaskReward]

    var effectVFXURL: String? { rewards.compactMap(\.rewardAsset?.vfxURL).first }
    var hasSVGAEffect: Bool { effectVFXURL?.lowercased().contains(".svga") == true }

    init?(payload: [String: Any]) {
        let rewards = PartyWeeklyTaskPage.firstArray(in: payload, keys: ["rewards"])
            .compactMap(PartyHotTaskReward.init(dictionary:))
        guard !rewards.isEmpty else { return nil }
        self.liveTime = PartyWeeklyTaskPage.firstInt(
            in: payload,
            keys: ["liveValue", "liveTime", "accumulatedDuration"]
        ) ?? 0
        self.rewards = rewards
    }
}

struct PartyHotTaskReward: Identifiable, Equatable {
    let name: String
    let amount: String
    let rewardType: Int?
    let effectiveHours: Int?
    let rewardAsset: PartyHotTaskRewardAsset?
    var id: String { "\(name)-\(amount)-\(rewardType ?? -1)-\(effectiveHours ?? -1)" }

    init?(dictionary: [String: Any]) {
        let name = PartyWeeklyTaskPage.firstString(in: dictionary, keys: ["rewardName", "name"]) ?? ""
        let amount = PartyWeeklyTaskPage.firstString(in: dictionary, keys: ["gems", "rewardValue", "amount", "value"])
        guard !name.isEmpty || amount != nil else { return nil }
        self.name = name
        self.amount = amount ?? ""
        self.rewardType = PartyWeeklyTaskPage.firstInt(in: dictionary, keys: ["rewardType"])
        self.effectiveHours = PartyWeeklyTaskPage.firstInt(in: dictionary, keys: ["effectiveHours"])
        self.rewardAsset = PartyHotTaskRewardAsset.decode(from: dictionary, key: "extendJson")
    }
}
