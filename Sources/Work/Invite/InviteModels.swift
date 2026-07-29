import Foundation

/// Invite 的两条独立收益线。协议值与安卓/H5 共用：1=用户，2=主播。
enum InviteAudience: Int, CaseIterable, Identifiable {
    case user = 1
    case anchor = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .user: return L10n.Invite.inviteUser
        case .anchor: return L10n.Invite.inviteAnchor
        }
    }
}

enum InviteRankingTab: String, CaseIterable, Identifiable {
    case myRewards
    case totalBonus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .myRewards: return L10n.Invite.myRewards
        case .totalBonus: return L10n.Invite.totalBonus
        }
    }
}

enum InviteDetailTab: String, CaseIterable, Identifiable {
    case invitedUsers
    case rewardRecords

    var id: String { rawValue }

    var title: String {
        switch self {
        case .invitedUsers: return L10n.Invite.invitedUsers
        case .rewardRecords: return L10n.Invite.rewardRecords
        }
    }
}

enum InviteDashboardPeriod: String, CaseIterable, Identifiable {
    case today
    case thisWeek
    case lastWeek
    case lastMonth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return L10n.Invite.today
        case .thisWeek: return L10n.Invite.thisWeek
        case .lastWeek: return L10n.Invite.lastWeek
        case .lastMonth: return L10n.Invite.lastMonth
        }
    }
}

struct InviteDashboard: Equatable {
    let summary: InviteStatistics
    let ruleText: String
    let userShare: InviteShareInfo
    let anchorShare: InviteShareInfo
    let anchorInfo: InviteAnchorInfo
    let marquee: [InviteRankItem]
    let rewards: InviteRewardRates
}

struct InviteRewardRates: Equatable {
    let user: String
    let anchor: String

    var userCommission: String { InviteRewardRates.percentText(InviteRewardRates.fraction(from: user)) }
    var anchorCommission: String { InviteRewardRates.percentText(InviteRewardRates.fraction(from: anchor)) }

    private static func fraction(from raw: String) -> Double {
        guard let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return 0 }
        return value > 1 ? value / 100 : value
    }

    private static func percentText(_ fraction: Double) -> String {
        let value = fraction * 100
        if value.rounded() == value { return "\(Int(value))%" }
        return String(format: "%.2f%%", value)
    }
}

struct InviteStatistics: Decodable, Equatable {
    let invitedCount: Int
    let awardTotal: String

    init(invitedCount: Int = 0, awardTotal: String = "0") {
        self.invitedCount = invitedCount
        self.awardTotal = awardTotal
    }

    private enum CodingKeys: String, CodingKey {
        case inviteUserNum, inviteAnchorNum, inviteNum, awardTotal, totalAward, totalReward
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        invitedCount = c.decodeFlexibleInt(forKey: .inviteUserNum)
            ?? c.decodeFlexibleInt(forKey: .inviteAnchorNum)
            ?? c.decodeFlexibleInt(forKey: .inviteNum)
            ?? 0
        awardTotal = c.decodeFlexibleString(forKey: .awardTotal)
            ?? c.decodeFlexibleString(forKey: .totalAward)
            ?? c.decodeFlexibleString(forKey: .totalReward)
            ?? "0"
    }
}

struct InviteShareInfo: Decodable, Equatable {
    let code: String
    let url: String
    let posterContent: String
    /// 后端不同环境的海报字段名存在历史差异；为空时由客户端生成可分享海报。
    let posterImageURL: String

    init(code: String = "", url: String = "", posterContent: String = "", posterImageURL: String = "") {
        self.code = code
        self.url = url
        self.posterContent = posterContent
        self.posterImageURL = posterImageURL
    }

    private enum CodingKeys: String, CodingKey {
        case code, inviteCode, url, inviteUrl, posterContent
        case posterUrl, posterImageUrl, posterImage, posterImg, poster, shareImage, shareImg, imageUrl, imgUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = c.decodeFlexibleString(forKey: .code)
            ?? c.decodeFlexibleString(forKey: .inviteCode)
            ?? ""
        url = c.decodeFlexibleString(forKey: .inviteUrl)
            ?? c.decodeFlexibleString(forKey: .url)
            ?? ""
        posterContent = c.decodeFlexibleString(forKey: .posterContent) ?? ""
        posterImageURL = c.decodeFlexibleString(forKey: .posterUrl)
            ?? c.decodeFlexibleString(forKey: .posterImageUrl)
            ?? c.decodeFlexibleString(forKey: .posterImage)
            ?? c.decodeFlexibleString(forKey: .posterImg)
            ?? c.decodeFlexibleString(forKey: .poster)
            ?? c.decodeFlexibleString(forKey: .shareImage)
            ?? c.decodeFlexibleString(forKey: .shareImg)
            ?? c.decodeFlexibleString(forKey: .imageUrl)
            ?? c.decodeFlexibleString(forKey: .imgUrl)
            ?? ""
    }
}

struct InviteAnchorInfo: Decodable, Equatable {
    let downloadURL: String
    let inviteCode: String
    let faqURL: String
    let policyURL: String

    init(downloadURL: String = "", inviteCode: String = "", faqURL: String = "", policyURL: String = "") {
        self.downloadURL = downloadURL
        self.inviteCode = inviteCode
        self.faqURL = faqURL
        self.policyURL = policyURL
    }

    private enum CodingKeys: String, CodingKey {
        case downloadUrl, inviteCode, faqurl, policyUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downloadURL = c.decodeFlexibleString(forKey: .downloadUrl) ?? ""
        inviteCode = c.decodeFlexibleString(forKey: .inviteCode) ?? ""
        faqURL = c.decodeFlexibleString(forKey: .faqurl) ?? ""
        policyURL = c.decodeFlexibleString(forKey: .policyUrl) ?? ""
    }
}

/// 邀请列表、总返佣榜、跑马灯共用的宽容展示模型。
struct InviteRankItem: Decodable, Identifiable, Equatable {
    let userID: String
    let nickname: String
    let iconURL: String?
    let awardTotal: String
    let createdAt: Int64?

    var id: String { "\(userID)-\(createdAt ?? 0)-\(nickname)" }

    private enum CodingKeys: String, CodingKey {
        case userId, uid, anchorId, anchorUid
        case nickname, nickName, anchorNickname, anchorNickName
        case icon, avatar, anchorIcon
        case awardTotal, awardAmount, totalAward, rewardIncome, totalReward
        case createTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = c.decodeFlexibleString(forKey: .userId)
            ?? c.decodeFlexibleString(forKey: .uid)
            ?? c.decodeFlexibleString(forKey: .anchorId)
            ?? c.decodeFlexibleString(forKey: .anchorUid)
            ?? UUID().uuidString
        nickname = c.decodeFlexibleString(forKey: .nickname)
            ?? c.decodeFlexibleString(forKey: .nickName)
            ?? c.decodeFlexibleString(forKey: .anchorNickname)
            ?? c.decodeFlexibleString(forKey: .anchorNickName)
            ?? L10n.anonymous
        iconURL = c.decodeFlexibleString(forKey: .icon)
            ?? c.decodeFlexibleString(forKey: .avatar)
            ?? c.decodeFlexibleString(forKey: .anchorIcon)
        awardTotal = c.decodeFlexibleString(forKey: .awardTotal)
            ?? c.decodeFlexibleString(forKey: .awardAmount)
            ?? c.decodeFlexibleString(forKey: .totalAward)
            ?? c.decodeFlexibleString(forKey: .rewardIncome)
            ?? c.decodeFlexibleString(forKey: .totalReward)
            ?? "0"
        // H5 rewardRankItem 仅以 createTime 判定右侧展示日期；缺失时展示钻石收益。
        createdAt = c.decodeFlexibleString(forKey: .createTime).flatMap(Int64.init)
    }
}

struct InviteRewardRecord: Decodable, Identifiable, Equatable {
    let userID: String
    let nickname: String
    let iconURL: String?
    let amount: String
    let createdAt: Int64?

    var id: String { "\(userID)-\(createdAt ?? 0)-\(amount)-\(nickname)" }

    private enum CodingKeys: String, CodingKey {
        case userId, uid, nickname, nickName, icon, avatar, awardAmount, awardTotal, createTime, inviteTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = c.decodeFlexibleString(forKey: .userId) ?? c.decodeFlexibleString(forKey: .uid) ?? ""
        nickname = c.decodeFlexibleString(forKey: .nickname) ?? c.decodeFlexibleString(forKey: .nickName) ?? L10n.anonymous
        iconURL = c.decodeFlexibleString(forKey: .icon) ?? c.decodeFlexibleString(forKey: .avatar)
        amount = c.decodeFlexibleString(forKey: .awardAmount)
            ?? c.decodeFlexibleString(forKey: .awardTotal)
            ?? "0"
        createdAt = (c.decodeFlexibleString(forKey: .createTime)
            ?? c.decodeFlexibleString(forKey: .inviteTime)).flatMap(Int64.init)
    }
}

struct InviteAnchorDashboard: Decodable, Equatable {
    let anchors: [InviteAnchorDashboardRow]
    let totalReward: String

    init(anchors: [InviteAnchorDashboardRow], totalReward: String) {
        self.anchors = anchors
        self.totalReward = totalReward
    }

    private enum CodingKeys: String, CodingKey { case anchorVos, list, totalReward }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedAnchors = (try? c.decodeIfPresent([InviteAnchorDashboardRow].self, forKey: .anchorVos))
            ?? (try? c.decodeIfPresent([InviteAnchorDashboardRow].self, forKey: .list))
            ?? []
        // 安卓列表按总收益倒序；接口顺序不属于展示契约，客户端必须稳定排序。
        anchors = decodedAnchors.sorted(by: InviteAnchorDashboardRow.sortByTotalIncome)
        totalReward = c.decodeFlexibleString(forKey: .totalReward) ?? "0"
    }

}

struct InviteAnchorDashboardRow: Decodable, Identifiable, Equatable {
    let uid: String
    let nickname: String
    let totalIncome: String
    let giftIncome: String
    let diamondIncome: String

    var id: String { uid }

    private enum CodingKeys: String, CodingKey {
        case uid, userId, nickname, nickName, totalIncome
        case giftIncome, giftAward, giftReward
        case diamondIncome, diamondAward, rewardIncome
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = c.decodeFlexibleString(forKey: .uid) ?? c.decodeFlexibleString(forKey: .userId) ?? UUID().uuidString
        nickname = c.decodeFlexibleString(forKey: .nickname) ?? c.decodeFlexibleString(forKey: .nickName) ?? L10n.anonymous
        totalIncome = c.decodeFlexibleString(forKey: .totalIncome) ?? "0"
        giftIncome = c.decodeFlexibleString(forKey: .giftIncome)
            ?? c.decodeFlexibleString(forKey: .giftAward)
            ?? c.decodeFlexibleString(forKey: .giftReward)
            ?? "0"
        diamondIncome = c.decodeFlexibleString(forKey: .diamondIncome)
            ?? c.decodeFlexibleString(forKey: .diamondAward)
            ?? c.decodeFlexibleString(forKey: .rewardIncome)
            ?? "0"
    }

    static func sortByTotalIncome(_ lhs: Self, _ rhs: Self) -> Bool {
        let lhsIncome = decimalValue(lhs.totalIncome)
        let rhsIncome = decimalValue(rhs.totalIncome)
        if lhsIncome == rhsIncome { return lhs.uid < rhs.uid }
        return lhsIncome > rhsIncome
    }

    private static func decimalValue(_ value: String) -> Decimal {
        Decimal(
            string: value.replacingOccurrences(of: ",", with: ""),
            locale: Locale(identifier: "en_US_POSIX")
        ) ?? 0
    }
}

struct InviteAnchorDetail: Decodable, Equatable {
    let uid: String
    let iconURL: String?
    let cumulativeOutputReward: String
    let callIncome: String
    let giftIncome: String
    let averageConnectionRate: String
    let rankingNumber: String
    let level: String
    let cumulativeOnlineSeconds: Int
    let totalChatSeconds: Int
    let averageCallSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case uid, userId, icon, avatar, cumulativeOutputReward, callIncome, giftIncome
        case averageConnectionRate, rankingNum, level, cumulativeOnlineTime, totalChatTime, averageCallDuration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = c.decodeFlexibleString(forKey: .uid) ?? c.decodeFlexibleString(forKey: .userId) ?? ""
        iconURL = c.decodeFlexibleString(forKey: .icon) ?? c.decodeFlexibleString(forKey: .avatar)
        cumulativeOutputReward = c.decodeFlexibleString(forKey: .cumulativeOutputReward) ?? "0"
        callIncome = c.decodeFlexibleString(forKey: .callIncome) ?? "0"
        giftIncome = c.decodeFlexibleString(forKey: .giftIncome) ?? "0"
        averageConnectionRate = c.decodeFlexibleString(forKey: .averageConnectionRate) ?? "0%"
        rankingNumber = c.decodeFlexibleString(forKey: .rankingNum) ?? "0"
        level = c.decodeFlexibleString(forKey: .level) ?? "0"
        cumulativeOnlineSeconds = c.decodeFlexibleInt(forKey: .cumulativeOnlineTime) ?? 0
        totalChatSeconds = c.decodeFlexibleInt(forKey: .totalChatTime) ?? 0
        averageCallSeconds = c.decodeFlexibleInt(forKey: .averageCallDuration) ?? 0
    }
}

struct InviteSharePayload: Identifiable {
    let id = UUID()
    let audience: InviteAudience
    let code: String
    let url: String
    let text: String
    let posterImageURL: String
}

enum InviteDateFormatter {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let detailDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()

    static func dateText(_ date: Date) -> String { dateFormatter.string(from: date) }

    static func display(_ timestamp: Int64?) -> String {
        guard let timestamp, timestamp > 0 else { return "--" }
        let seconds = timestamp > 10_000_000_000 ? Double(timestamp) / 1_000 : Double(timestamp)
        return dateFormatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    static func detailDisplay(_ timestamp: Int64?) -> String {
        guard let timestamp, timestamp > 0 else { return "--" }
        let seconds = timestamp > 10_000_000_000 ? Double(timestamp) / 1_000 : Double(timestamp)
        return detailDateFormatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    static func duration(_ seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }
}
