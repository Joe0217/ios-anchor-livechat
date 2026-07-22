import Foundation

/// 猜拳获胜通知（attachType 144）的展示字段。
/// H5 按 `grantedHours ?? medalHours` 取值，并兼容后端混发的数值类型。
struct RpsWinNotificationPayload: Equatable {
    let nickname: String?
    let medalURL: String?
    let medalHours: Double?

    init(data: [String: Any], fallbackNickname: String?) {
        nickname = Self.nonEmptyString(data["nickname"]) ?? fallbackNickname
        medalURL = Self.nonEmptyString(data["medalUrl"])

        // 与 JS 的 nullish coalescing 保持一致：只在 grantedHours 缺失/null 时读取 medalHours。
        let rawHours = Self.nonNullValue(data["grantedHours"]) ?? Self.nonNullValue(data["medalHours"])
        medalHours = Self.numberValue(rawHours)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func nonNullValue(_ value: Any?) -> Any? {
        guard let value, !(value is NSNull) else { return nil }
        return value
    }

    private static func numberValue(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        if let number = value as? NSNumber {
            let type = String(cString: number.objCType)
            guard type != "c", type != "B" else { return nil }
            let value = number.doubleValue
            return value.isFinite ? value : nil
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            // JavaScript `Number("")` is 0; keep the H5 rendering contract for empty backend strings.
            if trimmed.isEmpty { return 0 }
            guard let value = Double(trimmed), value.isFinite else { return nil }
            return value
        }
        return nil
    }
}
