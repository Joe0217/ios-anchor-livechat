import Foundation

/// 虚拟道具模型（M1 Step 1a · spec §3.3 · 零 SDK 依赖）。
///
/// **蓝本**：H5 `anchor-livechat-h5/src/views/virtualProps/index.vue` + `sapi/marketing/index.ts`
///
/// **⚠️ 字段名待真机 log 验证**（spec R31 硬 gate · agent-recon-field-names-unverified rule）：
/// - Codable init 内已铺 CodingKey alias 骨架，Step 3 首次拉取 log 抓 `dataKeys=` 对齐后清理
/// - id 字段 String/Int 双兼容（ios-decode-userid-compat rule）
/// - expireTime 严格 H5 语义（仅 `"-1"` / `-1` = permanent；其他数值走 timestamp）

// MARK: - PropItemType

/// 5 种道具类型（含 Entrance=3 供 decode，Tab 层用 `PropTabItemType` 收窄禁用）。
enum PropItemType: Int, Codable, CaseIterable, Equatable, Sendable {
    case vehicle = 1
    case frame = 2
    case entrance = 3
    case chatSkin = 4
    case cardFrame = 5
}

/// Tab & fetchPage 参数用（编译期禁 Entrance · spec §3.3）。
enum PropTabItemType: Int, CaseIterable, Equatable, Sendable {
    case vehicle = 1
    case frame = 2
    case chatSkin = 4
    case cardFrame = 5

    /// Tab 顺序（对齐 H5 tabList：All / Frame / Vehicle / ChatSkin / CardFrame）
    static let tabOrder: [PropTabItemType?] = [nil, .frame, .vehicle, .chatSkin, .cardFrame]

    /// All Tab 时前端过滤用（对齐 H5 enabledItemTypes）
    static let allTabAllowedRawValues: Set<Int> = Set(PropTabItemType.allCases.map(\.rawValue))
}

// MARK: - PropEquipAction

/// 佩戴/卸下操作（H5 代码实测：0=卸下 / 1=穿戴 · spec B4 待 Step 3 真机确认）。
enum PropEquipAction: Int, Codable, Equatable, Sendable {
    case unequip = 0
    case equip = 1
}

// MARK: - PropExpireTime

/// 道具有效期（严格对齐 H5 · spec §3.3 / D9 / D10 / R13 / R14）。
///
/// **判定规则**：
/// - String `"-1"` 或 Int `-1` → `.permanent`
/// - 值 `< 10^10` → 视为秒级 UNIX epoch
/// - `10^10 ~ 10^13` → 视为毫秒级 → 除以 1000
/// - `> 10^13` → 越界 fallback `.permanent`（防御性 · 不 crash）
enum PropExpireTime: Equatable, Sendable {
    case permanent
    case timestamp(TimeInterval)  // 秒级 UNIX epoch

    var isPermanent: Bool {
        if case .permanent = self { return true }
        return false
    }

    /// 返回从当前时间到到期的剩余秒数（负数 = 已过期）
    func remainingSecondsFromNow(now: Date = Date()) -> TimeInterval? {
        switch self {
        case .permanent: return nil
        case .timestamp(let epochSec): return epochSec - now.timeIntervalSince1970
        }
    }

    /// H5 格式 "xD:xxH:xxM"（无秒 · `remainingSeconds <= 0` → "0D:00H:00M"）
    static func format(remaining seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86400
        let h = (s % 86400) / 3600
        let m = (s % 3600) / 60
        return String(format: "%dD:%02dH:%02dM", d, h, m)
    }

    /// 从后端 Int64 值构造（自动判秒/毫秒/越界）
    static func fromEpoch(_ n: Int64) -> PropExpireTime {
        if n == -1 { return .permanent }
        if n < 10_000_000_000 { return .timestamp(TimeInterval(n)) }  // 秒
        if n < 10_000_000_000_000 { return .timestamp(TimeInterval(n) / 1000) }  // 毫秒
        return .permanent  // 越界兜底
    }
}

extension PropExpireTime: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            if s == "-1" { self = .permanent; return }
            if let n = Int64(s) {
                self = Self.fromEpoch(n)
                return
            }
            self = .permanent  // 字符串无法解析兜底
            return
        }
        if let n = try? c.decode(Int64.self) {
            self = Self.fromEpoch(n)
            return
        }
        if let n = try? c.decode(Int.self) {
            self = Self.fromEpoch(Int64(n))
            return
        }
        self = .permanent
    }
}

// MARK: - PropItem

/// 单个虚拟道具（H5 records[i]）· spec §3.3。
///
/// **CodingKey 双 alias 骨架**：真机 log 后清理未命中的 fallback（R31 硬 gate）。
struct PropItem: Decodable, Identifiable, Equatable, Sendable {
    let id: Int64
    let itemType: PropItemType
    let itemName: String
    let itemImg: String        // 大图 / 动效资源 URL
    let itemSmallImg: String   // grid 缩略图 URL
    let isFromBag: Int         // 0/1
    let wearStatus: Int        // 0/1
    let expireTime: PropExpireTime

    /// 便利：是否已穿戴
    var isWorn: Bool { wearStatus == 1 }

    /// 便利：是否已拥有
    var isOwned: Bool { isFromBag == 1 }

    /// SVGA/MP4/静图判断（spec D11 · `lowercased().contains(...)` 兼容 query string）
    var isSVGAResource: Bool { itemImg.lowercased().contains(".svga") }
    var isMP4Resource: Bool {
        let s = itemImg.lowercased()
        return s.contains(".mp4") || s.contains(".webm")
    }

    enum CodingKeys: String, CodingKey {
        // iOS 命名 + H5 候选 alias（Step 3 真机对齐后清理）
        case id, itemId, propId
        case itemType, type
        case itemName, name
        case itemImg, imgUrl, img
        case itemSmallImg, smallImg, thumbUrl
        case isFromBag, fromBag, owned
        case wearStatus, equipped, wear
        case expireTime, expireAt, expiryTs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // id · String/Int 双兼容（ios-decode-userid-compat rule）
        if let n = try? c.decode(Int64.self, forKey: .id) { id = n }
        else if let s = try? c.decode(String.self, forKey: .id), let n = Int64(s) { id = n }
        else if let n = try? c.decode(Int64.self, forKey: .itemId) { id = n }
        else if let s = try? c.decode(String.self, forKey: .itemId), let n = Int64(s) { id = n }
        else if let n = try? c.decode(Int64.self, forKey: .propId) { id = n }
        else if let s = try? c.decode(String.self, forKey: .propId), let n = Int64(s) { id = n }
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: c,
                debugDescription: "id neither Int nor String"
            )
        }

        // itemType · 未知 raw value fail-loud（避免静默丢字段）
        if let raw = try? c.decode(Int.self, forKey: .itemType),
           let t = PropItemType(rawValue: raw) {
            itemType = t
        } else if let raw = try? c.decode(Int.self, forKey: .type),
                  let t = PropItemType(rawValue: raw) {
            itemType = t
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .itemType, in: c,
                debugDescription: "itemType missing or unknown rawValue"
            )
        }

        // 其他字段 · 各字段 alias 兜底
        itemName = (try? c.decode(String.self, forKey: .itemName))
            ?? (try? c.decode(String.self, forKey: .name))
            ?? ""

        itemImg = (try? c.decode(String.self, forKey: .itemImg))
            ?? (try? c.decode(String.self, forKey: .imgUrl))
            ?? (try? c.decode(String.self, forKey: .img))
            ?? ""

        itemSmallImg = (try? c.decode(String.self, forKey: .itemSmallImg))
            ?? (try? c.decode(String.self, forKey: .smallImg))
            ?? (try? c.decode(String.self, forKey: .thumbUrl))
            ?? itemImg  // fallback 大图

        isFromBag = (try? c.decode(Int.self, forKey: .isFromBag))
            ?? (try? c.decode(Int.self, forKey: .fromBag))
            ?? (try? c.decode(Int.self, forKey: .owned))
            ?? 0

        wearStatus = (try? c.decode(Int.self, forKey: .wearStatus))
            ?? (try? c.decode(Int.self, forKey: .equipped))
            ?? (try? c.decode(Int.self, forKey: .wear))
            ?? 0

        // expireTime · PropExpireTime.init(from:) 内自处理
        if c.contains(.expireTime) {
            expireTime = (try? c.decode(PropExpireTime.self, forKey: .expireTime)) ?? .permanent
        } else if c.contains(.expireAt) {
            expireTime = (try? c.decode(PropExpireTime.self, forKey: .expireAt)) ?? .permanent
        } else if c.contains(.expiryTs) {
            expireTime = (try? c.decode(PropExpireTime.self, forKey: .expiryTs)) ?? .permanent
        } else {
            expireTime = .permanent
        }
    }

    /// 测试/preview 便利构造器
    init(
        id: Int64,
        itemType: PropItemType,
        itemName: String,
        itemImg: String,
        itemSmallImg: String? = nil,
        isFromBag: Int,
        wearStatus: Int,
        expireTime: PropExpireTime
    ) {
        self.id = id
        self.itemType = itemType
        self.itemName = itemName
        self.itemImg = itemImg
        self.itemSmallImg = itemSmallImg ?? itemImg
        self.isFromBag = isFromBag
        self.wearStatus = wearStatus
        self.expireTime = expireTime
    }

    /// 生成"改变 wearStatus 后"的副本（乐观更新 + 回滚用）
    func withWearStatus(_ new: Int) -> PropItem {
        PropItem(
            id: id, itemType: itemType, itemName: itemName,
            itemImg: itemImg, itemSmallImg: itemSmallImg,
            isFromBag: isFromBag, wearStatus: new, expireTime: expireTime
        )
    }
}

// MARK: - PropPage

/// 分页响应体（H5 apiGetVirtualItemPage.result）· spec §3.3。
struct PropPage: Decodable, Equatable, Sendable {
    let records: [PropItem]
    let totalNum: Int

    /// 便利：手写构造（测试/fake 用）
    init(records: [PropItem], totalNum: Int) {
        self.records = records
        self.totalNum = totalNum
    }

    enum CodingKeys: String, CodingKey {
        case records, list, items
        case totalNum, total, totalCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // records 双 alias + skipMalformed（skip 未知 itemType 而非 fail-loud · R16）
        var raw: [PropItem] = []
        if let arr = try? c.decode([FailableItem].self, forKey: .records) {
            raw = arr.compactMap(\.value)
        } else if let arr = try? c.decode([FailableItem].self, forKey: .list) {
            raw = arr.compactMap(\.value)
        } else if let arr = try? c.decode([FailableItem].self, forKey: .items) {
            raw = arr.compactMap(\.value)
        }
        records = raw

        totalNum = (try? c.decode(Int.self, forKey: .totalNum))
            ?? (try? c.decode(Int.self, forKey: .total))
            ?? (try? c.decode(Int.self, forKey: .totalCount))
            ?? 0
    }

    /// 内部 wrapper · decode 失败的单项 skip 而非整个 records 挂（R16）
    private struct FailableItem: Decodable {
        let value: PropItem?
        init(from decoder: Decoder) throws {
            value = try? PropItem(from: decoder)
        }
    }
}
