import Foundation

/// 首页跑马灯 item（H5 `getLiveMarqueeList` 响应）。
///
/// H5 `liveList.vue` 模板字段：
/// - `icon` 送礼用户头像
/// - `nickname` 送礼用户昵称
/// - `diamond` 礼物钻石金额（后端 Number / String 混发）
///
/// 其他字段（`userId` / `giftId` / `giftName` 等）本次不用；后续 H 里程碑接入完整
/// 礼物模块时再展开。
struct GiftMarqueeItem: Identifiable, Equatable {
    let id: String
    let icon: String?
    let nickname: String
    let diamond: String

    var iconURL: URL? {
        guard let s = icon, !s.isEmpty else { return nil }
        return URL(string: s)
    }
}

extension GiftMarqueeItem {
    /// 从字典解码。id 优先取 `userId`（H5 用户维度去重）；缺则用 nickname + diamond 拼一个稳定 id。
    /// 类型 String/Int 混发按 `.claude/rules/ios-decode-userid-compat.md` 兼容。
    init?(from dict: [String: Any]) {
        // userId → id（H5 侧未明确 marqueeItem 的 key field，但 userId 相对稳）
        let rawId: String
        if let s = dict["userId"] as? String, !s.isEmpty {
            rawId = s
        } else if let n = dict["userId"] as? NSNumber {
            let cType = String(cString: n.objCType)
            rawId = (cType == "c" || cType == "B") ? "" : n.stringValue
        } else {
            rawId = ""
        }

        // diamond 字符串化——UI 直接显示
        let d: String
        if let s = dict["diamond"] as? String, !s.isEmpty {
            d = s
        } else if let n = dict["diamond"] as? NSNumber {
            let cType = String(cString: n.objCType)
            d = (cType == "c" || cType == "B") ? "0" : n.stringValue
        } else {
            d = "0"
        }

        let nick = (dict["nickname"] as? String) ?? ""
        let ic = dict["icon"] as? String

        // id fallback：userId 缺失时用 nickname + diamond 拼稳定 key（避免 UUID 每次不同触发 diff 抖动）
        let finalId = rawId.isEmpty ? "\(nick)#\(d)" : rawId
        guard !finalId.isEmpty else { return nil }

        self.id = finalId
        self.icon = ic
        self.nickname = nick
        self.diamond = d
    }
}

// MARK: - Service protocol

/// 跑马灯数据层协议——真集成走 `GiftMarqueeService.shared`，单测注入 Fake。
protocol GiftMarqueeServiceProtocol {
    /// 拉一轮跑马灯（H5 每次进 Live 广场调一次，无参）。
    func fetchMarquee() async throws -> [GiftMarqueeItem]
}
