import Foundation

/// 礼物模型（对齐 H5 `src/api/gift/type.ts:1-8` GiftListData）。
///
/// **iOS decode 兼容策略**（`.claude/rules/ios-decode-userid-compat.md`）：
/// - `id`：H5 类型是 number；iOS 严格 Int64 decode + String 兼容（后端未来改类型也不炸）
/// - `giftPrice`：同上；单位是主播端本币最小单位（对齐 H5，不做单位转换）
///
/// 字段 `vaild`（H5 typo 保留原名）：1 有效 / 0 失效；本模型保留字段但 UI 层不做过滤（后端已下发有效礼物列表）。
public struct GiftListData: Codable, Equatable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let giftPrice: Int64
    public let giftSmallImg: String
    public let giftImg: String
    public let vaild: Int?
    /// 礼物分类。Party 房 Lucky Gift 的消息可能不直接携带类型，需要用礼物架元数据兜底。
    public let category: String?
    /// 后端礼物类型，`6` 表示 Lucky Gift（与 H5 `giftTypeV2 === 6` 对齐）。
    public let giftTypeV2: Int?

    public init(
        id: Int64,
        name: String,
        giftPrice: Int64,
        giftSmallImg: String,
        giftImg: String,
        vaild: Int? = nil,
        category: String? = nil,
        giftTypeV2: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.giftPrice = giftPrice
        self.giftSmallImg = giftSmallImg
        self.giftImg = giftImg
        self.vaild = vaild
        self.category = category
        self.giftTypeV2 = giftTypeV2
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, giftPrice, giftSmallImg, giftImg, vaild, category, giftTypeV2
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try Self.decodeInt64(c, key: .id)
        self.name = (try? c.decode(String.self, forKey: .name)) ?? ""
        self.giftPrice = try Self.decodeInt64(c, key: .giftPrice)
        self.giftSmallImg = (try? c.decode(String.self, forKey: .giftSmallImg)) ?? ""
        self.giftImg = (try? c.decode(String.self, forKey: .giftImg)) ?? ""
        self.vaild = try? c.decode(Int.self, forKey: .vaild)
        self.category = try? c.decode(String.self, forKey: .category)
        self.giftTypeV2 = Self.decodeOptionalInt(c, key: .giftTypeV2)
    }

    /// H5 Party 房 Lucky Gift 的礼物架兜底条件。
    public var isLuckyGift: Bool {
        category == "Lucky Gift" || giftTypeV2 == 6
    }

    /// String / Int64 双兼容 decode（H5 type.ts 类型声明与后端实际混发）
    private static func decodeInt64(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Int64 {
        if let i = try? c.decode(Int64.self, forKey: key) { return i }
        if let s = try? c.decode(String.self, forKey: key), let i = Int64(s) { return i }
        throw DecodingError.dataCorruptedError(forKey: key, in: c,
            debugDescription: "\(key) neither Int64 nor String")
    }

    private static func decodeOptionalInt(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Int? {
        if let i = try? c.decode(Int.self, forKey: key) { return i }
        if let s = try? c.decode(String.self, forKey: key), let i = Int(s) { return i }
        return nil
    }
}
