import Foundation

/// 通用 Codable 兼容 helper —— 后端 API 字段偶发混发 String / Int / Double / null 时的兜底 decode。
///
/// 对齐 [ios-decode-userid-compat](.claude/rules/ios-decode-userid-compat.md) 精神:
/// H5 接口混发数字/字符串是常态,严格 `try container.decode(Int.self)` 会 fail-loud;
/// iOS 用这两个 helper 做静默兜底。
///
/// **原位置**:抽自 Sources/Profile/ProfileModels.swift(2026-07-17 H 里程碑 · LiveGiftTask spec §4
/// 移到通用位置以便 HilyTests target 白名单精确 include,避免整个 ProfileModels 入测)。
extension KeyedDecodingContainer {
    /// String 版:接口混发 Int / String / Double 时的兼容 decode
    func decodeFlexibleString(forKey key: Key) -> String? {
        // `try?` 已把 `T??` flatten 成 `T?`(Swift 5+),单层 if let 就够;
        // 若再写 `, let s` 是对已解开的 non-optional String 再解一次 → "conditional binding must have Optional" 报错
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int64.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(Int64(d)) }
        return nil
    }

    /// Int 版:接口混发 Int / String / Double 时的兼容 decode
    func decodeFlexibleInt(forKey key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let s = try? decodeIfPresent(String.self, forKey: key), let i = Int(s) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        return nil
    }

    /// Bool 版:审核接口会混发 Bool、0/1 和 "true"/"false" 字符串。
    func decodeFlexibleBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = decodeFlexibleInt(forKey: key) { return value != 0 }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "y": return true
            case "false", "no", "n", "": return false
            default: return nil
            }
        }
        return nil
    }
}
