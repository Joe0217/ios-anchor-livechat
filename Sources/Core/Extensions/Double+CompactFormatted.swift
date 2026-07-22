import Foundation

/// K/M 差值格式化（spec §6.4）
///
/// `1_000_000 → M` / `1_000 → K` / 保留 2 位小数（若整数则去尾）
/// 用于 PartyBattle RunningHud 分数显示 / 后续通用金额展示复用。
extension Double {
    var compactFormatted: String {
        let n = self
        if n >= 1_000_000 {
            let m = n / 1_000_000
            return m.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(m))M" : String(format: "%.2fM", m)
        }
        if n >= 1_000 {
            let k = n / 1_000
            return k.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(k))K" : String(format: "%.2fK", k)
        }
        return n.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(n))" : String(format: "%.2f", n)
    }
}
