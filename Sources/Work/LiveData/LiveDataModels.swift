import Foundation

/// Live Data 查询期间。数字与 H5 后端 `dateType` 参数完全对齐（`liveData/index.vue:19-45`）。
///
/// | queryType | 含义                | UI 分组   |
/// |-----------|---------------------|-----------|
/// | 0         | 本周 this week      | Weekly    |
/// | 1         | 上周 last week      | Weekly    |
/// | 2         | 本月 this month     | Monthly   |
/// | 3         | 上月 last month     | Monthly   |
/// | 4         | 两月前 twoMonthsAgo | Monthly   |
enum LiveDataDateType: Int, CaseIterable, Hashable {
    case thisWeek = 0
    case lastWeek = 1
    case thisMonth = 2
    case lastMonth = 3
    case twoMonthsAgo = 4

    enum Segment: String, Hashable, CaseIterable { case weekly, monthly }

    var segment: Segment {
        switch self {
        case .thisWeek, .lastWeek: return .weekly
        case .thisMonth, .lastMonth, .twoMonthsAgo: return .monthly
        }
    }

    /// 是否为"当前进行时"（this week / this month）—— 决定倒计时行是否显示（对齐 H5 `value === 'this'`）
    var isCurrent: Bool { self == .thisWeek || self == .thisMonth }

    static func children(of seg: Segment) -> [LiveDataDateType] {
        switch seg {
        case .weekly: return [.thisWeek, .lastWeek]
        case .monthly: return [.thisMonth, .lastMonth, .twoMonthsAgo]
        }
    }
}

// MARK: - 后端响应

/// `/api/anchor/live/authorLiveData` 返回体。
/// 字段名来源：H5 `liveData/index.vue:78-91` 直接消费 `res.xxx`。
///
/// **decode 策略**：`decodeIfPresent ?? 0` —— 字段名严格（CodingKeys 声明，keyNotFound 也退到 0），
/// 字段值容忍 null（对齐 H5 8 处 `|| 0` 兜底：新账号无历史 / 单日无收益 / 非当前期间 remainingTime 缺失）。
/// 上一轮严格 `try c.decode` 会让新账号首次进入 → DecodingError → fullScreenError + Retry 永远修不好（round2 audit finding #1/#2 高危 regression）。
/// 若真机首次拉取发现字段名偏差 → 加 CodingKeys alias（agent-recon-field-names-unverified rule）。
struct LiveDataResponse: Decodable {
    let totalDurationSecondsCount: Int
    let totalIncomeDiamondsCount: Int
    let liveIncomeDiamondsCount: Int
    let privateCallIncomeDiamondsCount: Int
    /// 当前 dateType 对应期间的剩余秒数（this week 到周日 24:00 之类）。仅 isCurrent=true 时有意义；
    /// 非当前期间后端可能不发（H5 index.vue:79 `res.remainingTime * 1000` undefined 时 NaN 客户端静默兼容）
    let remainingTime: Int
    let dataList: [LiveDataDay]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalDurationSecondsCount = (try? c.decodeIfPresent(Int.self, forKey: .totalDurationSecondsCount)) ?? 0
        totalIncomeDiamondsCount = (try? c.decodeIfPresent(Int.self, forKey: .totalIncomeDiamondsCount)) ?? 0
        liveIncomeDiamondsCount = (try? c.decodeIfPresent(Int.self, forKey: .liveIncomeDiamondsCount)) ?? 0
        privateCallIncomeDiamondsCount = (try? c.decodeIfPresent(Int.self, forKey: .privateCallIncomeDiamondsCount)) ?? 0
        remainingTime = (try? c.decodeIfPresent(Int.self, forKey: .remainingTime)) ?? 0
        dataList = try? c.decodeIfPresent([LiveDataDay].self, forKey: .dataList)
    }

    enum CodingKeys: String, CodingKey {
        case totalDurationSecondsCount, totalIncomeDiamondsCount
        case liveIncomeDiamondsCount, privateCallIncomeDiamondsCount
        case remainingTime, dataList
    }
}

/// dataList 单项。statDate 是稳定的 ForEach identity 来源（View 层 `ForEach(.., id: \.statDate)`）。
/// id 字段做 String/Int 双兼容（ios-decode-userid-compat rule），但仅在后端严格返回时使用。
/// 数值字段严格 decode 让字段名偏差 fail-loud。
struct LiveDataDay: Decodable, Identifiable, Hashable {
    /// 后端 id（若返回 String → 直接用；若 Int → toString；若缺失 → 用 statDate）。
    /// 全工程仅 Identifiable 需要，无其他消费者。
    let id: String
    /// 日期字符串（如 "2026-07-14"，H5 不解析直接展示）
    let statDate: String
    let totalDurationSeconds: Int
    let totalIncomeDiamonds: Int
    let liveIncomeDiamonds: Int
    let privateCallIncomeDiamonds: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // statDate 保持严格 —— ForEach id + Store expandedDates key，缺失会破坏 identity
        statDate = try c.decode(String.self, forKey: .statDate)
        // id 双兼容：优先 id 字段，缺失时用 statDate 作 fallback（无独立 identity 消费者）
        if let s = try? c.decode(String.self, forKey: .id) {
            id = s
        } else if let i = try? c.decode(Int64.self, forKey: .id) {
            id = String(i)
        } else {
            id = statDate
        }
        // 4 个数值字段用 decodeIfPresent + ?? 0 —— 单日 null 是合法业务态（某天只做直播没接私 call
        // → privateCallIncomeDiamonds=null；对齐 H5 index.vue:326-376 逐 item `|| 0` 兜底）；
        // 严格 decode 会让单日 null 撒毒整个 dataList array（Swift array decode 是原子的）→ 整月列表消失。
        totalDurationSeconds = (try? c.decodeIfPresent(Int.self, forKey: .totalDurationSeconds)) ?? 0
        totalIncomeDiamonds = (try? c.decodeIfPresent(Int.self, forKey: .totalIncomeDiamonds)) ?? 0
        liveIncomeDiamonds = (try? c.decodeIfPresent(Int.self, forKey: .liveIncomeDiamonds)) ?? 0
        privateCallIncomeDiamonds = (try? c.decodeIfPresent(Int.self, forKey: .privateCallIncomeDiamonds)) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case id, statDate, totalDurationSeconds
        case totalIncomeDiamonds, liveIncomeDiamonds, privateCallIncomeDiamonds
    }
}

/// `/api/task/v2/get` 部分响应，只取浮标钻石数（对齐 H5 `liveData/index.vue:136-139` 仅消费 sureGetAward）。
/// sureGetAward 缺失时兜底 0 —— 该字段属可选浮标数据，不影响主页面数据展示，静默 0 合理（对齐 H5 || 0）。
struct MoneyBagResponse: Decodable {
    let sureGetAward: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sureGetAward = (try? c.decode(Int.self, forKey: .sureGetAward)) ?? 0
    }

    enum CodingKeys: String, CodingKey { case sureGetAward }
}

// MARK: - 展示 helpers

enum LiveDataFormatter {
    /// 秒 → HH:MM:SS（对齐 H5 `secondsToTime`）
    static func hhmmss(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }
}
