import Foundation

/// 派对房排麦申请项（房主端 `getQueueSeatList` records 元素）。
///
/// 字段名来源：H5 `stores/modules/party.js` 起草推断；真机 log 未验证前所有可选字段用 alias 兜底
/// 见 `.claude/rules/agent-recon-field-names-unverified.md` + `.claude/rules/ios-decode-userid-compat.md`
struct PartyMicApplication: Decodable, Identifiable, Equatable {
    /// String/Int 双兼容（后端 userId 混发；见 ios-decode-userid-compat rule）
    let userId: String
    let nickname: String
    let avatar: String?
    /// 头像框装饰 URL（对齐安卓 MicApplicationInfo.headFrame/SmallImg）；.svga / .png / .webp 均可能
    let headFrame: String?
    let gender: Int?
    let age: Int?
    let userType: Int?
    let levelName: String?
    let vip: Int?
    let seatType: Int?
    let seatIndex: Int?
    /// 是否允许上接待位（对齐安卓 MicApplicationInfo.canOnHostSeat）；nil / false 时房主批准
    /// 挑首空位应排除 isHostSeat=1 的位；true 时允许
    let canOnHostSeat: Bool?

    var id: String { userId }

    // 灵活字段 key —— agent 侦察阶段字段名未真机 log 验证，起草期先都写候选
    private struct AnyKey: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)

        // userId String/Int 双兼容 —— 后端可能返 "1000001877" 或 1000001877
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

        // nickname alias: nickname / nick / userName / name
        self.nickname = Self.decodeString(c, keys: ["nickname", "nick", "userName", "name"]) ?? ""

        // avatar alias: avatar / head / userIcon / headImg / userAvatar
        self.avatar = Self.decodeString(c, keys: ["avatar", "head", "userIcon", "headImg", "userAvatar"])

        // headFrame alias: headFrame / headFrameSmallImg / smallImg（对齐 PartyRoomSeat + PartyUserBasicInfo 已用字段名）
        self.headFrame = Self.decodeString(c, keys: ["headFrame", "headFrameSmallImg", "smallImg", "userIconFrame"])

        // levelName alias: levelName / lv / levelStr / level / userLevel（level/userLevel 后端可能是 Int，兜底 stringValue）
        if let s = Self.decodeString(c, keys: ["levelName", "lv", "levelStr", "level", "userLevel"]) {
            self.levelName = s
        } else if let n = Self.decodeInt(c, keys: ["level", "userLevel"]) {
            self.levelName = String(n)
        } else {
            self.levelName = nil
        }

        self.gender = try? c.decode(Int.self, forKey: AnyKey(stringValue: "gender")!)
        self.age = try? c.decode(Int.self, forKey: AnyKey(stringValue: "age")!)
        self.userType = try? c.decode(Int.self, forKey: AnyKey(stringValue: "userType")!)
        self.vip = try? c.decode(Int.self, forKey: AnyKey(stringValue: "vip")!)
        self.seatType = try? c.decode(Int.self, forKey: AnyKey(stringValue: "seatType")!)
        self.seatIndex = try? c.decode(Int.self, forKey: AnyKey(stringValue: "seatIndex")!)
        // canOnHostSeat 可能是 Bool 或 Int (1/0)；双兼容
        if let b = try? c.decode(Bool.self, forKey: AnyKey(stringValue: "canOnHostSeat")!) {
            self.canOnHostSeat = b
        } else if let n = try? c.decode(Int.self, forKey: AnyKey(stringValue: "canOnHostSeat")!) {
            self.canOnHostSeat = (n != 0)
        } else {
            self.canOnHostSeat = nil
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

    private static func decodeInt(_ c: KeyedDecodingContainer<AnyKey>, keys: [String]) -> Int? {
        for k in keys {
            guard let key = AnyKey(stringValue: k) else { continue }
            if let v = try? c.decode(Int.self, forKey: key) {
                return v
            }
        }
        return nil
    }
}

/// 观众端"我的申请"状态快照。
///
/// - `inIndex > 0`：申请中且排队位序为 inIndex；`0` = 未申请
/// - `rejectedAt`：上次被拒时间戳；30s 冷却用（防 spam re-apply）
struct PartyMyApplyInfo: Equatable {
    var inIndex: Int = 0
    var rejectedAt: Date? = nil
}

/// 房主端排麦申请列表状态机（对齐 list-refresh-preserve-items rule）。
///
/// `refreshing` 保留旧 items 视觉，避免下拉刷新时列表消失
enum PartyMicApplicationsState: Equatable {
    case idle
    case loading
    case loaded([PartyMicApplication])
    case refreshing([PartyMicApplication])
    case empty
    case error(String)
}
