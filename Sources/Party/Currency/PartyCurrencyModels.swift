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

enum PartyCurrencyDecodeError: Error, Equatable {
    case responseNotObject
    case balanceFieldsMissing
}
