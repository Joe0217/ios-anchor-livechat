import Foundation

/// 派对房主播资产账户。宝石允许服务端以小数下发，但兑换仅接受正整数宝石数。
struct PartyCurrencyBalance: Equatable, Sendable {
    let diamonds: Int64
    let gems: Decimal
    let coins: Int64

    static let empty = PartyCurrencyBalance(diamonds: 0, gems: 0, coins: 0)

    var availableWholeGems: Int64 {
        let behavior = NSDecimalNumberHandler(
            roundingMode: .down,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )
        return NSDecimalNumber(decimal: gems)
            .rounding(accordingToBehavior: behavior)
            .int64Value
    }

    var gemsDisplayValue: String {
        NSDecimalNumber(decimal: gems).stringValue
    }

    static func decode(from data: Data) throws -> PartyCurrencyBalance {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PartyCurrencyDecodeError.responseNotObject
        }

        let payload = payloadDictionary(in: object)
        guard hasKnownBalanceField(in: payload) else {
            throw PartyCurrencyDecodeError.balanceFieldsMissing
        }

        return PartyCurrencyBalance(
            diamonds: int64Value(in: payload, keys: ["diamond", "diamonds", "diamondNum", "balance"]) ?? 0,
            gems: decimalValue(in: payload, keys: ["gem", "gems"]) ?? 0,
            coins: int64Value(in: payload, keys: ["coin", "coins", "gold", "goldCoin"]) ?? 0
        )
    }

    private static func payloadDictionary(in object: [String: Any]) -> [String: Any] {
        guard !hasKnownBalanceField(in: object) else { return object }
        for key in ["data", "result", "balance"] {
            if let nested = object[key] as? [String: Any] {
                return nested
            }
        }
        return object
    }

    private static func hasKnownBalanceField(in object: [String: Any]) -> Bool {
        ["diamond", "diamonds", "diamondNum", "balance", "gem", "gems", "coin", "coins", "gold", "goldCoin"]
            .contains { object[$0] != nil }
    }

    private static func int64Value(in object: [String: Any], keys: [String]) -> Int64? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let number = value as? NSNumber {
                let type = String(cString: number.objCType)
                guard type != "c", type != "B" else { continue }
                return number.int64Value
            }
            if let string = value as? String,
               let number = Int64(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return number
            }
        }
        return nil
    }

    private static func decimalValue(in object: [String: Any], keys: [String]) -> Decimal? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let number = value as? NSNumber {
                let type = String(cString: number.objCType)
                guard type != "c", type != "B" else { continue }
                return Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
            }
            if let string = value as? String {
                return Decimal(
                    string: string.trimmingCharacters(in: .whitespacesAndNewlines),
                    locale: Locale(identifier: "en_US_POSIX")
                )
            }
        }
        return nil
    }
}

enum PartyCurrencyTarget: String, CaseIterable, Hashable, Sendable {
    case diamond
    case coin
}

/// Work 资产卡点击后的落页 tab。与兑换目标分开，避免 Gems 卡被误解释成“兑换到金币”。
enum PartyCurrencyWalletTab: String, CaseIterable, Hashable, Sendable {
    case diamonds
    case gems
}

/// 一条资产变动流水。服务端目前以 `id / remark / createTime / costNum` 下发，
/// 解析时同时兼容历史字段别名，避免旧记录页因字段演进整页不可用。
struct PartyCurrencyRecord: Identifiable, Equatable, Sendable {
    let id: String
    let cursor: String?
    let remark: String
    let amount: Decimal
    let timestampMilliseconds: Int64?

    static func decodeList(from data: Data, page: Int) throws -> [PartyCurrencyRecord] {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let values = extractList(from: raw) else {
            throw PartyCurrencyDecodeError.recordListMissing
        }

        return values.enumerated().compactMap { index, value in
            guard let item = value as? [String: Any] else { return nil }
            let cursor = stringValue(item["id"] ?? item["recordId"])
            let timestamp = int64Value(item["createTime"] ?? item["time"] ?? item["timestamp"])
            return PartyCurrencyRecord(
                id: cursor ?? "currency-\(page)-\(timestamp ?? 0)-\(index)",
                cursor: cursor,
                remark: stringValue(item["remark"] ?? item["description"] ?? item["title"]) ?? "",
                amount: decimalValue(item["costNum"] ?? item["amount"] ?? item["changeNum"] ?? item["num"]) ?? 0,
                timestampMilliseconds: timestamp
            )
        }
    }

    private static func extractList(from raw: Any) -> [Any]? {
        if let list = raw as? [Any] { return list }
        guard let object = raw as? [String: Any] else { return nil }
        for key in ["list", "records", "data", "result"] {
            guard let value = object[key] else { continue }
            if let list = extractList(from: value) {
                return list
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = int64Value(value) { return String(value) }
        return nil
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber {
            let type = String(cString: value.objCType)
            guard type != "c", type != "B" else { return nil }
            return value.int64Value
        }
        if let value = value as? String {
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func decimalValue(_ value: Any?) -> Decimal? {
        if let value = value as? NSNumber {
            let type = String(cString: value.objCType)
            guard type != "c", type != "B" else { return nil }
            return Decimal(string: value.stringValue, locale: Locale(identifier: "en_US_POSIX"))
        }
        if let value = value as? String {
            return Decimal(
                string: value.trimmingCharacters(in: .whitespacesAndNewlines),
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
        return nil
    }
}

enum PartyCurrencyDecodeError: Error, Equatable {
    case responseNotObject
    case balanceFieldsMissing
    case recordListMissing
}
