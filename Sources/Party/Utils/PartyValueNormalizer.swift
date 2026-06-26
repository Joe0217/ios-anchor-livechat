import Foundation

/// 跨通道值归一化（spec §1.5 v3 + 安卓确认 §3）。
///
/// **背景**：派对房 `roomId / userId / seatIndex` 等关键标识在不同通道类型不一致：
/// - HTTP 响应（`room/list` `room/enter` `seat/list`）：**String**
/// - NIM payload（1003 / 1012 / 2049 等）：**Number**
/// - WS 心跳上行：后端 `Convert.toLong` 两者都吃
///
/// 直接 `payload["x"] as? String` 遇 Number 会失败；反之亦然。
/// 本工具统一归到 String 比较（最宽容；不丢失 Long 精度）。
enum PartyValueNormalizer {

    /// 把任意 JSON 值归一为 String：
    /// - String 直接返回（去前后空白后判空）
    /// - Number（Int/Int64/Double/NSNumber）转为不带小数的字符串
    /// - 其他类型 / nil → nil
    static func stringify(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        if let n = value as? NSNumber {
            // NSNumber.stringValue 默认行为：整数返 "123"，小数返 "12.3"
            return n.stringValue
        }
        if let i = value as? Int {
            return String(i)
        }
        if let i = value as? Int64 {
            return String(i)
        }
        if let d = value as? Double {
            // 防止整数被打成 "123.0"；若小数部分为 0 则截掉
            return d.truncatingRemainder(dividingBy: 1) == 0 ? String(Int64(d)) : String(d)
        }
        return nil
    }

    /// 把任意 JSON 值归一为 Int：
    /// - Number 直接转
    /// - String 数字字符串可解析
    /// - 其他 → nil
    static func intify(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let i = value as? Int { return i }
        if let i = value as? Int64 { return Int(i) }
        if let n = value as? NSNumber { return n.intValue }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
