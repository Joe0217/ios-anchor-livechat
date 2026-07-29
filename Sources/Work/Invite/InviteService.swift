import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "InviteService")

protocol InviteServiceProtocol {
    func fetchDashboard() async throws -> InviteDashboard
    func fetchStatistics(audience: InviteAudience) async throws -> InviteStatistics
    func fetchBoundUsers(audience: InviteAudience, page: Int, pageSize: Int) async throws -> [InviteRankItem]
    func fetchTotalRewards() async throws -> [InviteRankItem]
    func fetchInviteDetails(kind: InviteDetailTab, startDate: Date?, endDate: Date?, keyword: String, page: Int, pageSize: Int) async throws -> [InviteRewardRecord]
    func fetchAnchorDashboard(period: InviteDashboardPeriod) async throws -> InviteAnchorDashboard
    func fetchAnchorDetail(uid: String) async throws -> InviteAnchorDetail
    func submitPunishmentAppeal(userID: String) async throws
}

final class InviteService: InviteServiceProtocol {
    static let shared = InviteService()
    private init() {}

    func fetchDashboard() async throws -> InviteDashboard {
        // H5 分别请求并独立处理失败；邀请页不能因某一张卡片缺数据而整体不可用。
        async let summaryData = bestEffort("summary", default: Data("{}".utf8)) {
            try await APIClient.shared.post("/api/anchor/getAnchorInviteUserStat", body: [:])
        }
        async let userCodeData = bestEffort("user code", default: Data("{}".utf8)) {
            try await APIClient.shared.post("/api/anchor/getAnchorShareUrl", body: [:])
        }
        async let anchorInfoData = bestEffort("anchor info", default: Data("{}".utf8)) {
            try await APIClient.shared.post("/api/anchor/inviteInfo", body: [:])
        }
        // 海报、跑马灯和远程配置都是展示增强项；单项失败必须保留主看板和邀请链接可用。
        async let marqueeData = bestEffort("marquee", default: Data("[]".utf8)) {
            try await APIClient.shared.post("/api/anchor/invite/user/award/list", body: [:])
        }
        async let userShareData = bestEffort("user poster", default: Data("{}".utf8)) {
            try await APIClient.shared.post("/api/anchor/invite/poster/floor", body: ["userType": InviteAudience.user.rawValue])
        }
        async let anchorShareData = bestEffort("anchor poster", default: Data("{}".utf8)) {
            try await APIClient.shared.post("/api/anchor/invite/poster/floor", body: ["userType": InviteAudience.anchor.rawValue])
        }
        async let rule = bestEffort("rule", default: "") { try await configValue("distribution_Invitation") }
        async let userReward = bestEffort("user reward", default: "") { try await configValue("invite_user_award") }
        async let anchorReward = bestEffort("anchor reward", default: "") { try await configValue("invite_anchor_award") }

        let (summaryRaw, userCodeRaw, anchorInfoRaw, marqueeRaw, userShareRaw, anchorShareRaw, ruleValue, userRewardValue, anchorRewardValue) = await (
            summaryData, userCodeData, anchorInfoData, marqueeData, userShareData, anchorShareData,
            rule, userReward, anchorReward
        )

        var userShare = try decode(InviteShareInfo.self, from: userShareRaw)
        let userCode = try decode(InviteShareInfo.self, from: userCodeRaw)
        if userShare.code.isEmpty || userShare.url.isEmpty {
            userShare = InviteShareInfo(
                code: userShare.code.isEmpty ? userCode.code : userShare.code,
                url: userShare.url.isEmpty ? userCode.url : userShare.url,
                posterContent: userShare.posterContent,
                posterImageURL: userShare.posterImageURL
            )
        }
        var anchorShare = try decode(InviteShareInfo.self, from: anchorShareRaw)
        let anchorInfo = try decode(InviteAnchorInfo.self, from: anchorInfoRaw)
        if anchorShare.code.isEmpty || anchorShare.url.isEmpty {
            anchorShare = InviteShareInfo(
                code: anchorShare.code.isEmpty ? anchorInfo.inviteCode : anchorShare.code,
                url: anchorShare.url.isEmpty ? anchorInfo.downloadURL : anchorShare.url,
                posterContent: anchorShare.posterContent,
                posterImageURL: anchorShare.posterImageURL
            )
        }

        return InviteDashboard(
            summary: try decode(InviteStatistics.self, from: summaryRaw),
            ruleText: ruleValue,
            userShare: userShare,
            anchorShare: anchorShare,
            anchorInfo: anchorInfo,
            marquee: try decodeArray(InviteRankItem.self, from: marqueeRaw),
            rewards: InviteRewardRates(user: userRewardValue, anchor: anchorRewardValue)
        )
    }

    func fetchStatistics(audience: InviteAudience) async throws -> InviteStatistics {
        let data = try await APIClient.shared.post("/api/anchor/v2/getAnchorInviteUserStat", body: ["userType": audience.rawValue])
        return try decode(InviteStatistics.self, from: data)
    }

    func fetchBoundUsers(audience: InviteAudience, page: Int, pageSize: Int) async throws -> [InviteRankItem] {
        let data = try await APIClient.shared.post(
            "/api/anchor/invite/user/list",
            body: ["userType": audience.rawValue, "currentPage": page, "pageSize": pageSize]
        )
        return try decodeArray(InviteRankItem.self, from: data)
    }

    func fetchTotalRewards() async throws -> [InviteRankItem] {
        let data = try await APIClient.shared.post("/api/anchor/invite/user/total/award/list", body: [:])
        return try decodeArray(InviteRankItem.self, from: data)
    }

    func fetchInviteDetails(kind: InviteDetailTab, startDate: Date?, endDate: Date?, keyword: String, page: Int, pageSize: Int) async throws -> [InviteRewardRecord] {
        let path: String
        switch kind {
        case .invitedUsers: path = "/api/anchor/queryAnchorInviteUserDetail"
        case .rewardRecords: path = "/api/anchor/queryAnchorInviteAwardRecord"
        }
        var body: [String: Any] = ["currentPage": page, "pageSize": pageSize, "keyword": keyword]
        if let startDate { body["startTime"] = InviteDateFormatter.dateText(startDate) }
        if let endDate { body["endTime"] = InviteDateFormatter.dateText(endDate) }
        let data = try await APIClient.shared.post(path, body: body)
        return try decodeArray(InviteRewardRecord.self, from: data)
    }

    func fetchAnchorDashboard(period: InviteDashboardPeriod) async throws -> InviteAnchorDashboard {
        let range = dateRange(for: period)
        let data = try await APIClient.shared.post(
            "/api/anchor/inviteAnchorListV2",
            body: [
                "currentPage": 1,
                "pageSize": 999,
                "key": "",
                "startTime": Int64(range.start.timeIntervalSince1970 * 1_000),
                "endTime": Int64(range.end.timeIntervalSince1970 * 1_000),
            ]
        )
        return try decode(InviteAnchorDashboard.self, from: data)
    }

    func fetchAnchorDetail(uid: String) async throws -> InviteAnchorDetail {
        let data = try await APIClient.shared.post("/api/anchor/inviteAnchorDetailV2", body: ["uid": uid])
        return try decode(InviteAnchorDetail.self, from: data)
    }

    /// H5 system message appeal: POST /api/face/appeal with the penalty user id.
    func submitPunishmentAppeal(userID: String) async throws {
        _ = try await APIClient.shared.post("/api/face/appeal", body: ["userId": userID])
    }

    private func configValue(_ key: String) async throws -> String {
        let data = try await APIClient.shared.post("/api/index/getConfigByKey", body: ["searchValue": key])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return InviteService.string(object[key])
    }

    private func bestEffort<T>(_ name: String, default fallback: T, operation: () async throws -> T) async -> T {
        do {
            return try await operation()
        } catch {
            logger.warning("Invite optional request=\(name, privacy: .public) failed: \(String(describing: error), privacy: .private)")
            return fallback
        }
    }

    private func dateRange(for period: InviteDashboardPeriod) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        switch period {
        case .today:
            return (today, calendar.date(byAdding: DateComponents(day: 1, second: -1), to: today) ?? now)
        case .thisWeek:
            let weekday = calendar.component(.weekday, from: today)
            let daysSinceMonday = (weekday + 5) % 7
            let thisMonday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today) ?? today
            return (thisMonday, calendar.date(byAdding: DateComponents(day: 1, second: -1), to: today) ?? now)
        case .lastWeek:
            let weekday = calendar.component(.weekday, from: today)
            let daysSinceMonday = (weekday + 5) % 7
            let thisMonday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today) ?? today
            let lastMonday = calendar.date(byAdding: .day, value: -7, to: thisMonday) ?? today
            return (lastMonday, calendar.date(byAdding: DateComponents(day: 7, second: -1), to: lastMonday) ?? now)
        case .lastMonth:
            let components = calendar.dateComponents([.year, .month], from: today)
            let startCurrentMonth = calendar.date(from: components) ?? today
            let startLastMonth = calendar.date(byAdding: .month, value: -1, to: startCurrentMonth) ?? today
            return (startLastMonth, calendar.date(byAdding: DateComponents(month: 1, second: -1), to: startLastMonth) ?? now)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            logger.error("Invite decode object=\(String(describing: T.self), privacy: .public) failed: \(String(describing: error), privacy: .private)")
            throw error
        }
    }

    private func decodeArray<T: Decodable>(_ type: T.Type, from data: Data) throws -> [T] {
        if let direct = try? JSONDecoder().decode([T].self, from: data) { return direct }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(code: "-1", message: L10n.commonNoContent)
        }
        for key in ["list", "data", "records", "anchorVos"] {
            guard let items = object[key], JSONSerialization.isValidJSONObject(items),
                  let itemData = try? JSONSerialization.data(withJSONObject: items),
                  let decoded = try? JSONDecoder().decode([T].self, from: itemData) else { continue }
            return decoded
        }
        return []
    }

    private static func string(_ value: Any?) -> String {
        switch value {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        default: return ""
        }
    }
}
