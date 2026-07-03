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

    public init(id: Int64, name: String, giftPrice: Int64, giftSmallImg: String, giftImg: String, vaild: Int? = nil) {
        self.id = id
        self.name = name
        self.giftPrice = giftPrice
        self.giftSmallImg = giftSmallImg
        self.giftImg = giftImg
        self.vaild = vaild
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, giftPrice, giftSmallImg, giftImg, vaild
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try Self.decodeInt64(c, key: .id)
        self.name = (try? c.decode(String.self, forKey: .name)) ?? ""
        self.giftPrice = try Self.decodeInt64(c, key: .giftPrice)
        self.giftSmallImg = (try? c.decode(String.self, forKey: .giftSmallImg)) ?? ""
        self.giftImg = (try? c.decode(String.self, forKey: .giftImg)) ?? ""
        self.vaild = try? c.decode(Int.self, forKey: .vaild)
    }

    /// String / Int64 双兼容 decode（H5 type.ts 类型声明与后端实际混发）
    private static func decodeInt64(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Int64 {
        if let i = try? c.decode(Int64.self, forKey: key) { return i }
        if let s = try? c.decode(String.self, forKey: key), let i = Int64(s) { return i }
        throw DecodingError.dataCorruptedError(forKey: key, in: c,
            debugDescription: "\(key) neither Int64 nor String")
    }
}
