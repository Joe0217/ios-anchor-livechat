import Foundation

/// 派对房黑名单项（`getKickOutBlacklist` records 元素，E spec §3）。
///
/// 字段名 / 类型来源：H5 `blocklist.vue` 消费点起草推断；真机 log 未验证前所有关键字段用 alias +
/// String/Int 双兼容兜底（见 `.claude/rules/agent-recon-field-names-unverified.md` +
/// `.claude/rules/ios-decode-userid-compat.md`）。
///
/// **spec §0 校验 point 1**：H5 用 `` `${banType}` === '1' `` 字符串比较判限时 —— 后端可能返 Int
/// 也可能 String，iOS 归一到 Int 侧统一 `isTemporary` 判定。
struct PartyBlocklistItem: Identifiable, Equatable, Decodable {
    /// String/Int 双兼容（后端 userId 混发）
    let userId: String
    let avatar: String?
    let nickname: String?
    /// 1=限时（有 duration 倒计时）/ 2=永久（duration 常为 0）
    let banType: Int
    /// 剩余秒数（限时才 >0；本地 tick 递减用 `mutating tick()`）
    private(set) var duration: Int
    let levelName: String?
    let vip: Int?
    /// 元素类型真机未验证，起草期先当 String 数组（decode 失败时兜底空数组避免整行挂）
    let medalList: [String]?
    let age: Int?
    /// 1=male / 2=female（H5 语义）
    let gender: Int?
    /// 后端可能返"被封禁时间戳"（秒 or 毫秒）—— 未真机验证前保留 alias 兜底
    let bannedAt: Int64?

    var id: String { userId }
    /// 限时封禁判定（对齐 H5 `` `${banType}` === '1' ``）
    var isTemporary: Bool { banType == 1 }

    /// 本地倒计时递减一秒；已到 0 不再减。归 0 后 row 仍显示，下次刷新才由后端移除（对齐 H5 clearCountdown 行为）
    mutating func tick() {
        if duration > 0 { duration -= 1 }
    }

    // 灵活 key —— agent 侦察阶段字段名未真机 log 验证，起草期先都写候选
    private struct AnyKey: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)

        // userId String/Int 双兼容
        let userIdKey = AnyKey(stringValue: "userId")!
        if let s = try? c.decode(String.self, forKey: userIdKey), !s.isEmpty {
            self.userId = s
        } else if let n = try? c.decode(Int64.self, forKey: userIdKey) {
            self.userId = String(n)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: userIdKey,
                in: c,
                debugDescription: "userId neither String nor Int64"
            )
        }

        // avatar / nickname alias
        self.avatar = Self.decodeString(c, keys: ["avatar", "head", "userIcon", "headImg", "userAvatar"])
        self.nickname = Self.decodeString(c, keys: ["nickname", "nick", "userName", "name"])

        // banType String/Int 双兼容 —— H5 用字符串比较；后端可能返 1 / "1" / 2 / "2"（spec §0 校验 point 1）
        self.banType = Self.decodeIntFlexible(c, keys: ["banType", "type"]) ?? 2

        // duration 同样 String/Int 双兼容；缺失 fallback 0（永久）
        self.duration = Self.decodeIntFlexible(c, keys: ["duration", "remainSeconds", "leftTime"]) ?? 0

        // levelName / vip / gender / age / medalList / bannedAt 全 optional 兜底
        if let s = Self.decodeString(c, keys: ["levelName", "lv", "levelStr"]) {
            self.levelName = s
        } else if let n = Self.decodeIntFlexible(c, keys: ["level", "userLevel"]) {
            self.levelName = String(n)
        } else {
            self.levelName = nil
        }
        self.vip = Self.decodeIntFlexible(c, keys: ["vip"])
        self.gender = Self.decodeIntFlexible(c, keys: ["gender", "sex"])
        self.age = Self.decodeIntFlexible(c, keys: ["age"])
        self.medalList = (try? c.decode([String].self, forKey: AnyKey(stringValue: "medalList")!))
            ?? (try? c.decode([String].self, forKey: AnyKey(stringValue: "medals")!))

        if let n = try? c.decode(Int64.self, forKey: AnyKey(stringValue: "bannedAt")!) {
            self.bannedAt = n
        } else if let n = try? c.decode(Int64.self, forKey: AnyKey(stringValue: "createTime")!) {
            self.bannedAt = n
        } else if let s = Self.decodeString(c, keys: ["bannedAt", "createTime"]),
                  let n = Int64(s) {
            self.bannedAt = n
        } else {
            self.bannedAt = nil
        }
    }

    private static func decodeString(_ c: KeyedDecodingContainer<AnyKey>, keys: [String]) -> String? {
        for k in keys {
            guard let key = AnyKey(stringValue: k) else { continue }
            if let v = try? c.decode(String.self, forKey: key), !v.isEmpty {
                return v
            }
        }
        return nil
    }

    /// Int/String 双兼容 decode —— 后端字段类型不稳（banType/duration 均命中）
    private static func decodeIntFlexible(_ c: KeyedDecodingContainer<AnyKey>, keys: [String]) -> Int? {
        for k in keys {
            guard let key = AnyKey(stringValue: k) else { continue }
            if let v = try? c.decode(Int.self, forKey: key) {
                return v
            }
            if let s = try? c.decode(String.self, forKey: key), let v = Int(s) {
                return v
            }
        }
        return nil
    }
}

/// 派对房黑名单列表状态机（对齐 [list-refresh-preserve-items.md](../../.claude/rules/list-refresh-preserve-items.md)）。
///
/// `refreshing` 中间态保留旧 items 视觉，避免下拉刷新时列表消失闪烁；
/// 无 items 可保留时（idle/empty/error）走 `.loading` 全屏 spinner。
enum PartyBlocklistState: Equatable {
    case idle
    case loading
    case loaded([PartyBlocklistItem])
    case refreshing([PartyBlocklistItem])
    case empty
    case error(String)
}

/// 黑名单列表拉取 reason（配合 list-refresh-preserve-items rule）。
/// `.initial` 首次开面板走 `.loading`；`.refresh` 有 items 时走 `.refreshing(items)` 保留视觉。
enum PartyBlocklistLoadReason {
    case initial
    case refresh
}
