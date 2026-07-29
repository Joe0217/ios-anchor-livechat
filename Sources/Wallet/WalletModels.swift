import Foundation

enum WalletLedgerFilter: String, CaseIterable, Identifiable {
    case call
    case gift
    case task
    case invite
    case message
    case interaction
    case others

    var id: String { rawValue }

    var sapiValue: String {
        switch self {
        case .message: return "unlock"
        default: return rawValue
        }
    }
}

struct WalletSummary: Equatable {
    let balance: String
    let balanceUSD: String
    let todayIncome: String

    init(object: [String: Any]) {
        balance = WalletJSON.string(object["myBalance"]) ?? "0"
        balanceUSD = WalletJSON.string(object["myBalanceDiv"]) ?? "0.00"
        todayIncome = WalletJSON.string(object["totalsIncome"]) ?? "0"
    }
}

struct WalletLedgerEntry: Equatable, Identifiable {
    let id: String
    let createTime: String
    let user: String
    let detail: String
    let source: String
    let income: String

    init(object: [String: Any], index: Int) {
        let rawCreateTime = WalletJSON.string(object["createTime"]) ?? ""
        createTime = WalletDateFormatter.display(object["createTime"])
        user = WalletJSON.string(object["user"]) ?? "-"
        detail = WalletJSON.string(object["detail"]) ?? "-"
        source = WalletJSON.string(object["source"]) ?? ""
        income = WalletJSON.string(object["income"] ?? object["flowValue"]) ?? "0"
        id = WalletJSON.string(object["id"] ?? object["billId"])
            ?? "\(rawCreateTime)-\(income)-\(index)"
    }

    /// H5 maps server-side task codes to the product source name instead of
    /// exposing implementation values such as `dailyTaskReward`.
    var taskSourceText: String {
        if !source.isEmpty { return source }
        let sourceMap = [
            "System Call Reward": "1V1",
            "Chat": "1V1",
            "cptask": "1V1",
            "eventReward": "PK",
            "activeTycoonReward": "Live",
            "dailyTaskReward": "\u{2014}\u{2014}",
            "newAnchorTaskReward": "\u{2014}\u{2014}",
            "cycleTaskReward": "\u{2014}\u{2014}",
            "onlineTimeTaskReward": "\u{2014}\u{2014}",
        ]
        let key = sourceMap[detail] == nil ? user : detail
        return sourceMap[key] ?? (detail.isEmpty ? "-" : detail)
    }
}

struct WithdrawalWallet: Equatable {
    let canWithdrawalAmount: Int64
    let diamondAmount: Int64
    let diamondRate: Int64
    let description: String

    init(object: [String: Any]) {
        canWithdrawalAmount = WalletJSON.int64(object["canWithdrawalAmount"]) ?? 0
        diamondAmount = WalletJSON.int64(object["diamondAmount"]) ?? 0
        diamondRate = WalletJSON.int64(object["diamondRate"]) ?? 0
        description = WalletJSON.string(object["description"]) ?? ""
    }
}

struct WithdrawalAccount: Equatable, Identifiable {
    let id: String
    let type: String
    let address: String
    let name: String
    let serviceCharge: Decimal

    init?(object: [String: Any]) {
        guard let id = WalletJSON.string(object["id"]), !id.isEmpty,
              let type = WalletJSON.string(object["accountType"]), !type.isEmpty,
              let address = WalletJSON.string(object["accountAddress"]), !address.isEmpty else {
            return nil
        }
        self.id = id
        self.type = type
        self.address = address
        // Older accounts can predate `accountName`. Keep them selectable and
        // use the same stable channel name supplied by the H5 add-account flow.
        name = WalletJSON.string(object["accountName"]) ?? Self.defaultName(for: type)
        serviceCharge = WalletJSON.decimal(object["serviceCharge"]) ?? 0
    }

    var displayTitle: String { "\(type): \(address)" }

    private static func defaultName(for type: String) -> String {
        switch type {
        case "Digifinex": return "UID"
        case "USDT": return "TRC20"
        default: return ""
        }
    }
}

struct WithdrawalPasswordConfig: Equatable {
    let isSet: Bool

    init(object: [String: Any]) {
        isSet = WalletJSON.bool(object["isSet"]) ?? false
    }
}

struct WithdrawalRecord: Equatable, Identifiable {
    let id: String
    let accountType: String
    let withdrawNum: String
    let billId: String
    let createTime: String
    let state: Int

    init(object: [String: Any], index: Int) {
        accountType = WalletJSON.string(object["accountType"]) ?? ""
        withdrawNum = WalletJSON.string(object["withdrawNum"]) ?? "0"
        billId = WalletJSON.string(object["billId"]) ?? ""
        createTime = WalletDateFormatter.display(object["createTime"])
        state = WalletJSON.int(object["state"]) ?? 0
        id = billId.isEmpty ? "\(WalletJSON.string(object["createTime"]) ?? "")-\(index)" : billId
    }
}

struct WithdrawalQuote: Equatable, Identifiable {
    let diamondAmount: Int64
    let grossUSD: Decimal
    let feePercent: Decimal
    let feeUSD: Decimal
    let finalUSD: Decimal
    let remainderDiamonds: Int64

    init(amount: Int64, rate: Int64, serviceCharge: Decimal) {
        diamondAmount = amount
        feePercent = serviceCharge
        let wholeDollars = rate > 0 ? amount / rate : 0
        grossUSD = Decimal(wholeDollars)
        feeUSD = WalletDecimal.round(grossUSD * serviceCharge / 100, scale: 2)
        finalUSD = WalletDecimal.round(grossUSD - feeUSD, scale: 2)
        remainderDiamonds = rate > 0 ? amount % rate : 0
    }

    var grossText: String { WalletNumberFormatter.currency(grossUSD) }
    var feeText: String { WalletNumberFormatter.currency(feeUSD) }
    var finalText: String { WalletNumberFormatter.currency(finalUSD) }
    var feePercentText: String { WalletNumberFormatter.percent(feePercent) }
    var id: Int64 { diamondAmount }
}

enum WithdrawalValidationError: Equatable {
    case missingAccount
    case missingAmount
    case invalidInteger
    case exceedsBalance
    case belowMinimumDiamond
    case belowExchangeRate
    case belowChannelMinimum
}

struct WithdrawalAuthorization: Equatable {
    let accountID: String
    let diamondAmount: Int64
    let faceVerified: Bool
}

enum WalletJSON {
    static func object(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw WalletServiceError.invalidResponse
        }
        return object
    }

    static func array(from data: Data) throws -> [[String: Any]] {
        guard let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [[String: Any]] else {
            throw WalletServiceError.invalidResponse
        }
        return object
    }

    static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber {
            let type = String(cString: value.objCType)
            return (type == "c" || type == "B") ? nil : value.stringValue
        }
        return nil
    }

    static func int64(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber {
            let type = String(cString: value.objCType)
            return (type == "c" || type == "B") ? nil : value.int64Value
        }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let value = value as? NSNumber {
            let type = String(cString: value.objCType)
            return (type == "c" || type == "B") ? nil : value.intValue
        }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func decimal(_ value: Any?) -> Decimal? {
        if let value = value as? NSDecimalNumber { return value.decimalValue }
        if let value = value as? NSNumber {
            let type = String(cString: value.objCType)
            return (type == "c" || type == "B") ? nil : value.decimalValue
        }
        if let value = value as? String {
            return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
        }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }
}

enum WalletNumberFormatter {
    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func currency(_ value: Decimal) -> String {
        currencyFormatter.string(from: NSDecimalNumber(decimal: value)) ?? "0.00"
    }

    static func percent(_ value: Decimal) -> String {
        percentFormatter.string(from: NSDecimalNumber(decimal: value)) ?? "0.0"
    }
}

private enum WalletDateFormatter {
    static func display(_ value: Any?) -> String {
        let raw = WalletJSON.string(value) ?? ""
        guard let timestamp = WalletJSON.int64(value), timestamp >= 946_684_800 else { return raw }
        let seconds = timestamp >= 100_000_000_000 ? TimeInterval(timestamp) / 1_000 : TimeInterval(timestamp)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }
}

private enum WalletDecimal {
    static func round(_ value: Decimal, scale: Int) -> Decimal {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, scale, .plain)
        return result
    }
}
