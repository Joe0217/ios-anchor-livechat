import Foundation

/// H5 `/dataStatistics` 页的三个接口数据契约。
/// 后端在不同环境中会把统计数值作为数字或字符串返回，因此统一保留展示字符串，避免解码失败。
struct DataStatisticsPreview: Decodable, Equatable {
    let likes: String
    let dislikes: String
    let dislikeRate: String

    enum CodingKeys: String, CodingKey { case likes, dislikes, dislikeRate }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        likes = c.displayValue(forKey: .likes)
        dislikes = c.displayValue(forKey: .dislikes)
        dislikeRate = c.displayValue(forKey: .dislikeRate)
    }
}

struct DataStatisticsLevelInfo: Decodable, Equatable {
    let answerRateThisWeek: String
    let answerRateLastWeek: String
    let avgDurationThisWeek: Int
    let avgDurationLastWeek: Int
    let callsThisWeek: String
    let callsLastWeek: String
    let updateTimeThisWeek: String
    let updateTimeLastWeek: String

    private enum RootKeys: String, CodingKey { case levelDataConfVos }
    private enum Keys: String, CodingKey {
        case levelAnswerRatePreveiw, levelAnswerRateLast
        case avgDurationPreveiw, avgDurationLast
        case levelCallsPreveiw, levelCallsLast
        case levelUpdateTimePreveiw, levelUpdateTimeLast
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        guard root.contains(.levelDataConfVos), !(try root.decodeNil(forKey: .levelDataConfVos)) else {
            self = .empty
            return
        }
        let c = try root.nestedContainer(keyedBy: Keys.self, forKey: .levelDataConfVos)
        answerRateThisWeek = c.displayValue(forKey: .levelAnswerRatePreveiw)
        answerRateLastWeek = c.displayValue(forKey: .levelAnswerRateLast)
        avgDurationThisWeek = c.intValue(forKey: .avgDurationPreveiw)
        avgDurationLastWeek = c.intValue(forKey: .avgDurationLast)
        callsThisWeek = c.displayValue(forKey: .levelCallsPreveiw)
        callsLastWeek = c.displayValue(forKey: .levelCallsLast)
        updateTimeThisWeek = c.dateValue(forKey: .levelUpdateTimePreveiw)
        updateTimeLastWeek = c.dateValue(forKey: .levelUpdateTimeLast)
    }

    static let empty = DataStatisticsLevelInfo(
        answerRateThisWeek: "-", answerRateLastWeek: "-", avgDurationThisWeek: 0,
        avgDurationLastWeek: 0, callsThisWeek: "-", callsLastWeek: "-",
        updateTimeThisWeek: "-", updateTimeLastWeek: "-"
    )

    private init(answerRateThisWeek: String, answerRateLastWeek: String, avgDurationThisWeek: Int,
                 avgDurationLastWeek: Int, callsThisWeek: String, callsLastWeek: String,
                 updateTimeThisWeek: String, updateTimeLastWeek: String) {
        self.answerRateThisWeek = answerRateThisWeek
        self.answerRateLastWeek = answerRateLastWeek
        self.avgDurationThisWeek = avgDurationThisWeek
        self.avgDurationLastWeek = avgDurationLastWeek
        self.callsThisWeek = callsThisWeek
        self.callsLastWeek = callsLastWeek
        self.updateTimeThisWeek = updateTimeThisWeek
        self.updateTimeLastWeek = updateTimeLastWeek
    }
}

struct DataStatisticsBenefits: Decodable, Equatable {
    let available: [String]
    let unavailable: [String]

    enum CodingKeys: String, CodingKey { case gradeEquityHave, gradeEquityNone }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = (try? c.decode([String].self, forKey: .gradeEquityHave)) ?? []
        unavailable = (try? c.decode([String].self, forKey: .gradeEquityNone)) ?? []
    }
}

struct DataStatisticsDeductionCondition: Decodable, Equatable {
    let points: String
    let pointsRequired: String
    let remainingChances: String
    let canDeduct: Bool

    enum CodingKeys: String, CodingKey { case anchorIntegral, integrate, deduction, isDeduction }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = c.displayValue(forKey: .anchorIntegral)
        pointsRequired = c.displayValue(forKey: .integrate)
        remainingChances = c.displayValue(forKey: .deduction)
        canDeduct = c.boolValue(forKey: .isDeduction)
    }
}

struct DataStatisticsDashboard: Equatable {
    let preview: DataStatisticsPreview
    let levelInfo: DataStatisticsLevelInfo
    let benefits: DataStatisticsBenefits
}

enum DataStatisticsFormatter {
    static func percentage(_ raw: String) -> String {
        guard raw != "-", let value = Double(raw) else { return raw }
        return value.rounded() == value ? String(Int(value)) : String(value)
    }

    static func date(_ raw: String) -> String {
        raw.count >= 10 ? String(raw.prefix(10)) : raw
    }

    static func duration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "-" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds % 60)
    }
}

private extension KeyedDecodingContainer {
    func displayValue(forKey key: Key) -> String {
        if let value = try? decodeIfPresent(String.self, forKey: key), !value.isEmpty { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(value) }
        return "-"
    }

    func intValue(forKey key: Key) -> Int {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int(value) ?? 0 }
        return 0
    }

    func boolValue(forKey key: Key) -> Bool {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value == "1" || value.lowercased() == "true"
        }
        return false
    }

    func dateValue(forKey key: Key) -> String {
        DataStatisticsFormatter.date(displayValue(forKey: key))
    }
}
