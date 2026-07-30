import Foundation

/// 首页 Banner 可接管的原生活动转盘路由。
///
/// 只接受受信任 activity H5 域的纯 `/lottery?lotteryId=...` 页面。排行榜和任务参数
/// 仍由 H5 承接，避免原生页丢失同页的其他活动能力。
struct LotteryRoute: Hashable {
    let activityID: String
    /// 仅作为 `/api/lottery/userLottery` 的 `url` 参数，保留活动来源供服务端归因。
    let sourceURL: String

    init?(url: URL) {
        guard url.user == nil,
              url.password == nil,
              H5TrustedOriginPolicy.activityH5.allows(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.fragment == nil,
              components.path
                .split(separator: "/")
                .last?
                .lowercased() == "lottery" else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        let directLotteryValues = queryItems
            .filter { $0.name == "lotteryId" }
            .compactMap(\.value)

        guard let rawLotteryID = Self.uniqueNonEmpty(directLotteryValues),
              directLotteryValues.allSatisfy({
                  $0.trimmingCharacters(in: .whitespacesAndNewlines) == rawLotteryID
              }) else {
            return nil
        }

        // H5 兼容历史 URL：`lotteryId=26%26taskId=9`。URLComponents 在不同系统版本
        // 可能已将 `%26` 解码为 `&`，故两种形式都归一后再解析。
        let normalizedLotteryValue = rawLotteryID.replacingOccurrences(
            of: "%26",
            with: "&",
            options: .caseInsensitive
        )
        let embeddedItems = Self.queryItems(fromEmbeddedLotteryID: normalizedLotteryValue)
        let activityID = normalizedLotteryValue
            .split(separator: "&", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !activityID.isEmpty else { return nil }

        // `activityId/taskId/rankType` 会在 H5 页面展开排行榜或任务 Tab。原生当前只实现
        // 抽奖主体，不能吞掉这些复合链接。
        for key in ["activityId", "taskId", "rankType"] {
            let directValues = queryItems.filter { $0.name == key }.compactMap(\.value)
            let embeddedValues = embeddedItems.filter { $0.name == key }.compactMap(\.value)
            let values = directValues + embeddedValues
            if values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return nil
            }
        }

        self.activityID = activityID
        self.sourceURL = url.absoluteString
    }

    private static func queryItems(fromEmbeddedLotteryID value: String) -> [URLQueryItem] {
        guard value.contains("&"),
              let components = URLComponents(string: "https://placeholder.invalid/?\(value)") else {
            return []
        }
        return components.queryItems ?? []
    }

    private static func uniqueNonEmpty(_ values: [String]) -> String? {
        let normalized = Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        guard normalized.count == 1 else { return nil }
        return normalized.first
    }
}

// MARK: - Activity

struct LotteryActivity: Equatable {
    let info: LotteryActivityInfo
    let prizes: [LotteryPrize]
    let assets: LotteryAssets
    let userTotalTimes: Int
    let pointProgress: LotteryPointProgress
    let popupConfiguration: LotteryPopupConfiguration?

    var supportsNativeGrid: Bool {
        prizes.count == 8 || prizes.count == 12
    }
}

struct LotteryActivityInfo: Decodable, Equatable {
    let name: String
    let lotteryStatus: Int
    let giftStatScene: String
    let startTime: String?
    let endTime: String?

    enum CodingKeys: String, CodingKey {
        case name = "activityName"
        case lotteryStatus, giftStatScene, startTime, endTime
    }

    static let empty = LotteryActivityInfo(
        name: "",
        lotteryStatus: 0,
        giftStatScene: "",
        startTime: nil,
        endTime: nil
    )

    init(name: String,
         lotteryStatus: Int,
         giftStatScene: String,
         startTime: String?,
         endTime: String?) {
        self.name = name
        self.lotteryStatus = lotteryStatus
        self.giftStatScene = giftStatScene
        self.startTime = startTime
        self.endTime = endTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.decodeFlexibleString(forKey: .name) ?? ""
        lotteryStatus = container.decodeFlexibleInt(forKey: .lotteryStatus) ?? 0
        giftStatScene = container.decodeFlexibleString(forKey: .giftStatScene) ?? ""
        startTime = container.decodeFlexibleString(forKey: .startTime)
        endTime = container.decodeFlexibleString(forKey: .endTime)
    }

    func phase(at date: Date = Date()) -> LotteryActivityPhase {
        guard let end = Self.date(from: endTime) else {
            // H5 以 start/end 时间作门禁。缺少 endTime 时按不可抽处理，避免运营配置异常时
            // 向后端发起真实抽奖请求。
            return .ended
        }
        if let start = Self.date(from: startTime), start > date {
            return .notStarted
        }
        return end > date ? .active : .ended
    }

    func countdownTarget(at date: Date = Date()) -> Date? {
        if let start = Self.date(from: startTime), start > date {
            return start
        }
        if let end = Self.date(from: endTime), end > date {
            return end
        }
        return nil
    }

    /// H5 `giftStatScene` 决定次数不足弹窗可跳转到的房间类型。空配置沿用历史双入口；
    /// 非空但不含已知场景时不展示误导性的跳转按钮。
    var insufficientRoomTargets: LotteryInsufficientRoomTargets {
        LotteryInsufficientRoomTargets(giftStatScene: giftStatScene)
    }

    private static func date(from raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let number = Double(raw) {
            let seconds = number > 10_000_000_000 ? number / 1_000 : number
            return Date(timeIntervalSince1970: seconds)
        }

        // 有明确时区的 ISO 字符串按其自身偏移解析；无时区字符串必须落到项目约定的
        // Asia/Shanghai，而不是 ISO8601DateFormatter 的 GMT 默认值。
        if hasExplicitTimeZone(raw) {
            let isoFormatter = ISO8601DateFormatter()
            if let date = isoFormatter.date(from: raw) { return date }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // 服务端无时区的活动时间按 H5 业务时区解释，不能跟随设备所在时区。
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    private static func hasExplicitTimeZone(_ raw: String) -> Bool {
        raw.hasSuffix("Z")
            || raw.range(of: #"[+-][0-9]{2}:?[0-9]{2}$"#, options: .regularExpression) != nil
    }
}

enum LotteryActivityPhase: Equatable {
    case notStarted
    case active
    case ended
}

/// 次数不足弹窗的入口来源。当前不接入埋点，仍保留来源以和 H5 三个入口保持同一业务状态。
enum LotteryDrawEntry: String, Equatable {
    case one
    case five
    case center
}

/// `/api/lottery/getRoomId` 的房间类型。
enum LotteryRoomTarget: Int, Equatable, Hashable {
    case live = 0
    case party = 1
}

struct LotteryInsufficientRoomTargets: Equatable {
    let showsLive: Bool
    let showsParty: Bool

    init(giftStatScene: String) {
        let scenes = Set(
            giftStatScene
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
                .filter { !$0.isEmpty }
        )

        guard !scenes.isEmpty else {
            showsLive = true
            showsParty = true
            return
        }

        let liveScenes: Set<String> = ["LIVE_ROOM", "PRIVATE_CALL", "LIVE", "LIVE_VIDEO"]
        showsLive = !scenes.isDisjoint(with: liveScenes)
        showsParty = scenes.contains("PARTY_GIFT")
    }

    var isPartyOnly: Bool {
        showsParty && !showsLive
    }
}

struct LotteryPrize: Decodable, Equatable, Identifiable {
    let id: String
    let iconURLString: String
    let name: String
    let prizeType: Int
    let validDays: Int
    let quantity: Int

    enum CodingKeys: String, CodingKey {
        case id, iconImage, prizeName, prizeType, validDays, quantity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeFlexibleString(forKey: .id) ?? ""
        iconURLString = container.decodeFlexibleString(forKey: .iconImage) ?? ""
        name = container.decodeFlexibleString(forKey: .prizeName) ?? ""
        prizeType = container.decodeFlexibleInt(forKey: .prizeType) ?? 0
        validDays = container.decodeFlexibleInt(forKey: .validDays) ?? 0
        quantity = container.decodeFlexibleInt(forKey: .quantity) ?? 0
    }

    var iconURL: URL? { LotteryAssets.safeURL(iconURLString) }
    var displayID: String { id.isEmpty ? "missing-\(name)-\(prizeType)" : id }
    var grantsAnotherChance: Bool { prizeType == 6 }

    var detailKind: LotteryPrizeDetailKind? {
        if prizeType == 1, quantity > 0 { return .quantity(quantity) }
        if [3, 4, 7, 8].contains(prizeType), validDays > 0 { return .days(validDays) }
        return nil
    }
}

enum LotteryPrizeDetailKind: Equatable {
    case quantity(Int)
    case days(Int)
}

struct LotteryPointProgress: Decodable, Equatable {
    let singleLotteryPoints: Int
    let currentPoints: Int
    let pointsToNext: Int
    let dailyChanceLimit: Int
    let dailyChanceUsed: Int
    let dailyChanceReached: Bool
    let sourceTextKey: String

    static let empty = LotteryPointProgress(
        singleLotteryPoints: 0,
        currentPoints: 0,
        pointsToNext: 0,
        dailyChanceLimit: 0,
        dailyChanceUsed: 0,
        dailyChanceReached: false,
        sourceTextKey: ""
    )

    init(singleLotteryPoints: Int,
         currentPoints: Int,
         pointsToNext: Int,
         dailyChanceLimit: Int,
         dailyChanceUsed: Int,
         dailyChanceReached: Bool,
         sourceTextKey: String) {
        self.singleLotteryPoints = singleLotteryPoints
        self.currentPoints = currentPoints
        self.pointsToNext = pointsToNext
        self.dailyChanceLimit = dailyChanceLimit
        self.dailyChanceUsed = dailyChanceUsed
        self.dailyChanceReached = dailyChanceReached
        self.sourceTextKey = sourceTextKey
    }

    enum CodingKeys: String, CodingKey {
        case singleLotteryPoints, currentPoints, pointsToNext
        case dailyChanceLimit, dailyChanceUsed, dailyChanceReached, sourceTextKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        singleLotteryPoints = container.decodeFlexibleInt(forKey: .singleLotteryPoints) ?? 0
        currentPoints = container.decodeFlexibleInt(forKey: .currentPoints) ?? 0
        pointsToNext = container.decodeFlexibleInt(forKey: .pointsToNext) ?? 0
        dailyChanceLimit = container.decodeFlexibleInt(forKey: .dailyChanceLimit) ?? 0
        dailyChanceUsed = container.decodeFlexibleInt(forKey: .dailyChanceUsed) ?? 0
        dailyChanceReached = container.decodeFlexibleBool(forKey: .dailyChanceReached) ?? false
        sourceTextKey = container.decodeFlexibleString(forKey: .sourceTextKey) ?? ""
    }

    var ratio: Double {
        if dailyChanceReached { return 1 }
        guard singleLotteryPoints > 0 else { return 0 }
        return min(1, max(0, Double(currentPoints) / Double(singleLotteryPoints)))
    }
}

// MARK: - Remote artwork

struct LotteryAssets: Equatable {
    private let values: [String: String]

    init(images: [LotteryImage]) {
        values = images.reduce(into: [:]) { result, image in
            let key = image.type.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = image.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { return }
            result[key] = value
        }
    }

    func url(for key: String) -> URL? {
        Self.safeURL(values[key] ?? "")
    }

    static func safeURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        return url
    }
}

struct LotteryImage: Decodable, Equatable {
    let type: String
    let urlString: String

    enum CodingKeys: String, CodingKey {
        case type = "imgType"
        case urlString = "imgUrl"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = container.decodeFlexibleString(forKey: .type) ?? ""
        urlString = container.decodeFlexibleString(forKey: .urlString) ?? ""
    }
}

struct LotteryPopupConfiguration: Decodable, Equatable {
    let popupType: Int
    let backgroundImageURLString: String
    let buttons: [LotteryPopupButton]

    enum CodingKeys: String, CodingKey {
        case popupType, backgroundImageURLString = "bgImage", buttons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        popupType = container.decodeFlexibleInt(forKey: .popupType) ?? 0
        backgroundImageURLString = container.decodeFlexibleString(forKey: .backgroundImageURLString) ?? ""
        buttons = (try? container.decodeIfPresent([LotteryPopupButton].self, forKey: .buttons)) ?? []
    }

    var backgroundImageURL: URL? {
        LotteryAssets.safeURL(backgroundImageURLString)
    }

    var usesCustomLayout: Bool {
        popupType == 2 && backgroundImageURL != nil
    }
}

struct LotteryPopupButton: Decodable, Equatable, Identifiable {
    let key: String
    let label: String
    let action: String
    let imageURLString: String

    var id: String { key.isEmpty ? "\(action)-\(label)" : key }

    enum CodingKeys: String, CodingKey {
        case key, label, action, imageURLString = "image"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = container.decodeFlexibleString(forKey: .key) ?? ""
        label = container.decodeFlexibleString(forKey: .label) ?? ""
        action = container.decodeFlexibleString(forKey: .action) ?? ""
        imageURLString = container.decodeFlexibleString(forKey: .imageURLString) ?? ""
    }

    var imageURL: URL? {
        LotteryAssets.safeURL(imageURLString)
    }

    var popupAction: LotteryPopupAction {
        LotteryPopupAction(rawAction: action)
    }
}

enum LotteryPopupAction: Equatable {
    case goPartyRoom
    case goLiveRoom
    case close
    case unknown

    init(rawAction: String) {
        switch rawAction.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "GO_PARTY_ROOM": self = .goPartyRoom
        case "GO_LIVE_ROOM": self = .goLiveRoom
        case "CLOSE": self = .close
        default: self = .unknown
        }
    }
}

// MARK: - Records

struct LotteryRewardRecord: Decodable, Equatable, Identifiable {
    let id: String
    let createdTime: String
    let userName: String
    let prizeName: String
    let prizeType: Int
    let validDays: Int
    let quantity: Int

    enum CodingKeys: String, CodingKey {
        case id, createdTime, userName, prizeName, prizeType, validDays, quantity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        createdTime = container.decodeFlexibleString(forKey: .createdTime) ?? ""
        userName = container.decodeFlexibleString(forKey: .userName) ?? ""
        prizeName = container.decodeFlexibleString(forKey: .prizeName) ?? ""
        prizeType = container.decodeFlexibleInt(forKey: .prizeType) ?? 0
        validDays = container.decodeFlexibleInt(forKey: .validDays) ?? 0
        quantity = container.decodeFlexibleInt(forKey: .quantity) ?? 0
    }

    var detailKind: LotteryPrizeDetailKind? {
        if prizeType == 1, quantity > 0 { return .quantity(quantity) }
        if [3, 4, 7, 8].contains(prizeType), validDays > 0 { return .days(validDays) }
        return nil
    }
}

enum LotteryDrawMode: Int {
    case one = 0
    case five = 1

    var requiredTimes: Int {
        switch self {
        case .one: return 1
        case .five: return 5
        }
    }
}
