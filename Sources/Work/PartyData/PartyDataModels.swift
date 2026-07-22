import Foundation

/// Party Data 查询期间。数字与安卓 `dateType` 参数完全对齐
/// (`PartyRoomDataActivity.kt`:105:`params["dateType"] = dateType`)
///
/// | queryType | 含义             | UI 分组   |
/// |-----------|------------------|-----------|
/// | 0         | 本周 this week   | Weekly    |
/// | 1         | 上周 last week   | Weekly    |
/// | 2         | 本月 this month  | Monthly   |
/// | 3         | 上月 last month  | Monthly   |
///
/// **无 twoMonthsAgo**——对齐安卓 `SelectTimeAreaDialog(includeTwoMonthsAgo=false)`（LiveStream 侧 true）。
enum PartyDataDateType: Int, CaseIterable, Hashable {
    case thisWeek = 0
    case lastWeek = 1
    case thisMonth = 2
    case lastMonth = 3

    enum Segment: String, Hashable, CaseIterable { case weekly, monthly }

    var segment: Segment {
        switch self {
        case .thisWeek, .lastWeek: return .weekly
        case .thisMonth, .lastMonth: return .monthly
        }
    }

    /// 是否为"当前进行时"——决定倒计时是否显示 + 麦时点击是否显示二级页 statDate 参数
    var isCurrent: Bool { self == .thisWeek || self == .thisMonth }

    static func children(of seg: Segment) -> [PartyDataDateType] {
        switch seg {
        case .weekly:  return [.thisWeek, .lastWeek]
        case .monthly: return [.thisMonth, .lastMonth]
        }
    }
}

// MARK: - 主看板响应

/// `POST /api/anchor/party/data/board` 响应体。
/// 字段对齐安卓 `PartyRoomDataEntity.java` (analysis §4)。
///
/// **decode 策略**：`decodeIfPresent ?? 0` —— 对齐 LiveDataResponse 兜底模式：
/// 新账号首次进入无历史数据、单期间无收入、非当前期间 countdownSeconds 缺失，严格 decode 会 fail-loud 破坏 UX。
struct PartyDataBoardResponse: Decodable {
    let periodStart: Int64
    let periodEnd: Int64
    let countdownSeconds: Int
    let micTimeSeconds: Int
    let micTimeVoiceSeconds: Int
    let micTimeVideoSeconds: Int
    let totalIncomeGems: Int
    let incomeBreakdown: PartyIncomeBreakdown
    let dailyList: [PartyRoomDaily]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        periodStart = (try? c.decodeIfPresent(Int64.self, forKey: .periodStart)) ?? 0
        periodEnd = (try? c.decodeIfPresent(Int64.self, forKey: .periodEnd)) ?? 0
        countdownSeconds = (try? c.decodeIfPresent(Int.self, forKey: .countdownSeconds)) ?? 0
        micTimeSeconds = (try? c.decodeIfPresent(Int.self, forKey: .micTimeSeconds)) ?? 0
        micTimeVoiceSeconds = (try? c.decodeIfPresent(Int.self, forKey: .micTimeVoiceSeconds)) ?? 0
        micTimeVideoSeconds = (try? c.decodeIfPresent(Int.self, forKey: .micTimeVideoSeconds)) ?? 0
        // totalIncomeGems 安卓侧是 BigDecimal, 后端多半整数 gems; 若真机发现小数由 decodeFlexibleInt 兼容
        totalIncomeGems = c.decodeFlexibleInt(forKey: .totalIncomeGems) ?? 0
        incomeBreakdown = (try? c.decodeIfPresent(PartyIncomeBreakdown.self, forKey: .incomeBreakdown)) ?? PartyIncomeBreakdown.zero
        dailyList = try? c.decodeIfPresent([PartyRoomDaily].self, forKey: .dailyList)
    }

    enum CodingKeys: String, CodingKey {
        case periodStart, periodEnd, countdownSeconds
        case micTimeSeconds, micTimeVoiceSeconds, micTimeVideoSeconds
        case totalIncomeGems, incomeBreakdown, dailyList
    }
}

/// 收入分项（3 项 vs Live Data 2 项）。安卓 `PartyIncomeBreakdownEntity`。
///
/// - `partyRoomGiftGems`：派对房收礼 (flow_scene=1)
/// - `partyCallGems`：Partycall 通话计费 (flow_scene=8, 含退款 10)
/// - `partyCallGiftGems`：Partycall 通话内礼物 (flow_scene=11)
///
/// UI 侧合并展示：**派对礼物收入 = partyRoomGiftGems**；**Partycall 收入 = partyCallGems + partyCallGiftGems**（对齐安卓 :137）
struct PartyIncomeBreakdown: Decodable, Hashable {
    let partyRoomGiftGems: Int
    let partyCallGems: Int
    let partyCallGiftGems: Int

    static let zero = PartyIncomeBreakdown(partyRoomGiftGems: 0, partyCallGems: 0, partyCallGiftGems: 0)

    /// UI 侧派生：Partycall 收入合并（计费+通话内礼物）
    var partyCallTotalGems: Int { partyCallGems + partyCallGiftGems }

    init(partyRoomGiftGems: Int, partyCallGems: Int, partyCallGiftGems: Int) {
        self.partyRoomGiftGems = partyRoomGiftGems
        self.partyCallGems = partyCallGems
        self.partyCallGiftGems = partyCallGiftGems
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        partyRoomGiftGems = c.decodeFlexibleInt(forKey: .partyRoomGiftGems) ?? 0
        partyCallGems = c.decodeFlexibleInt(forKey: .partyCallGems) ?? 0
        partyCallGiftGems = c.decodeFlexibleInt(forKey: .partyCallGiftGems) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case partyRoomGiftGems, partyCallGems, partyCallGiftGems
    }
}

/// 每日明细行（对齐安卓 `PartyRoomDailyEntity`）。
/// statDate 是稳定 ForEach identity 来源。
struct PartyRoomDaily: Decodable, Identifiable, Hashable {
    /// 日期字符串 "yyyy-MM-dd"
    let statDate: String
    let micTimeSeconds: Int
    let micTimeVoiceSeconds: Int
    let micTimeVideoSeconds: Int
    let totalIncomeGems: Int
    let incomeBreakdown: PartyIncomeBreakdown

    var id: String { statDate }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statDate = (try? c.decodeIfPresent(String.self, forKey: .statDate)) ?? ""
        micTimeSeconds = (try? c.decodeIfPresent(Int.self, forKey: .micTimeSeconds)) ?? 0
        micTimeVoiceSeconds = (try? c.decodeIfPresent(Int.self, forKey: .micTimeVoiceSeconds)) ?? 0
        micTimeVideoSeconds = (try? c.decodeIfPresent(Int.self, forKey: .micTimeVideoSeconds)) ?? 0
        totalIncomeGems = c.decodeFlexibleInt(forKey: .totalIncomeGems) ?? 0
        incomeBreakdown = (try? c.decodeIfPresent(PartyIncomeBreakdown.self, forKey: .incomeBreakdown)) ?? PartyIncomeBreakdown.zero
    }

    enum CodingKeys: String, CodingKey {
        case statDate
        case micTimeSeconds, micTimeVoiceSeconds, micTimeVideoSeconds
        case totalIncomeGems, incomeBreakdown
    }
}

// MARK: - 麦时二级页响应

/// 麦时详情按房间聚合项（安卓 `PartyMicTimeDetailEntity`）。
/// roomId 走 String/Int 双兼容（[ios-decode-userid-compat] rule）——业务 ID 类型统一策略。
struct PartyMicTimeDetailItem: Decodable, Identifiable, Hashable {
    let roomId: String
    let roomName: String
    let totalSeconds: Int
    let voiceSeconds: Int
    let videoSeconds: Int

    var id: String { roomId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .roomId) { roomId = s }
        else if let i = try? c.decode(Int64.self, forKey: .roomId) { roomId = String(i) }
        else { roomId = "" }
        roomName = (try? c.decodeIfPresent(String.self, forKey: .roomName)) ?? ""
        totalSeconds = (try? c.decodeIfPresent(Int.self, forKey: .totalSeconds)) ?? 0
        voiceSeconds = (try? c.decodeIfPresent(Int.self, forKey: .voiceSeconds)) ?? 0
        videoSeconds = (try? c.decodeIfPresent(Int.self, forKey: .videoSeconds)) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case roomId, roomName, totalSeconds, voiceSeconds, videoSeconds
    }
}
