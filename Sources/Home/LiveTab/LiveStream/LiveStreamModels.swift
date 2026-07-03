import Foundation

// MARK: - 业务模型

/// Live 广场卡片条目（H5 `getLiveList` 响应 item）。
///
/// 字段对齐 H5 `views/home/liveList.vue` 模板用法：
/// - `userId`（key field，接口 String/Int 混发 → 兼容收 String）
/// - `nickname` 主播昵称
/// - `icon` 头像 url（可空）
/// - `backgroundImgUrl` 直播封面 url（可空 → 走占位渐变）
/// - `joinNum` 观看人数（后端 Number 或 String）
/// - `weekIncome` 周收入胶囊（非空才显示）
/// - `pkStatus` PK 中标志（`=== 7` 时显示 PK 角标覆盖观看数）
/// - `diamondGiftActive` 钻石盲盒角标（`=== 1` 时显示）
/// - 加房相关字段（agoraChannelId / yxRoomId）先解出来放到 raw 里，客态里程碑再用
struct LiveStreamAnchor: Identifiable, Equatable {
    let userId: String
    let nickname: String
    let icon: String?
    let backgroundImgUrl: String?
    let joinNum: String
    let weekIncome: String?
    let pkStatus: Int?
    let diamondGiftActive: Int?

    var id: String { userId }

    /// PK 中显示 PK 角标（H5 `item?.pkStatus === 7`）
    var isInPK: Bool { pkStatus == 7 }

    /// 钻石盲盒角标（H5 `item.diamondGiftActive === 1`）
    var hasDiamondGift: Bool { diamondGiftActive == 1 }

    var backgroundImgURL: URL? {
        guard let s = backgroundImgUrl, !s.isEmpty else { return nil }
        return URL(string: s)
    }
}

extension LiveStreamAnchor {
    /// 从字典解码（走 JSONSerialization → dict → 手工构造）。
    /// 走手写解析而非 Codable，是因为 `userId` / `joinNum` 字段
    /// H5 侧 String/Int 混发（`.claude/rules/ios-decode-userid-compat.md`）。
    init?(from dict: [String: Any]) {
        // userId String/Int 混发
        let uid: String
        if let s = dict["userId"] as? String, !s.isEmpty {
            uid = s
        } else if let n = dict["userId"] as? NSNumber {
            let cType = String(cString: n.objCType)
            if cType == "c" || cType == "B" { return nil }
            uid = n.stringValue
        } else {
            return nil
        }

        // joinNum 同样 String/Int 混发；空/nil → "0"（保持 UI 直接显示）
        let watchNum: String
        if let s = dict["joinNum"] as? String, !s.isEmpty {
            watchNum = s
        } else if let n = dict["joinNum"] as? NSNumber {
            let cType = String(cString: n.objCType)
            watchNum = (cType == "c" || cType == "B") ? "0" : n.stringValue
        } else {
            watchNum = "0"
        }

        // weekIncome：接口可能 String/Number/空——空字符串等同 nil，卡片直接不渲染胶囊
        let income: String?
        if let s = dict["weekIncome"] as? String, !s.isEmpty {
            income = s
        } else if let n = dict["weekIncome"] as? NSNumber {
            let cType = String(cString: n.objCType)
            income = (cType == "c" || cType == "B") ? nil : n.stringValue
        } else {
            income = nil
        }

        self.userId = uid
        self.nickname = (dict["nickname"] as? String) ?? ""
        self.icon = dict["icon"] as? String
        self.backgroundImgUrl = dict["backgroundImgUrl"] as? String
        self.joinNum = watchNum
        self.weekIncome = income
        // pkStatus / diamondGiftActive 也可能被后端以 String 返回（H5 type.ts 不可信,
        // 见 .claude/rules/ios-decode-userid-compat.md）——String/Int 双兼容避免 PK 角标
        // 与钻石盲盒角标失显
        self.pkStatus = Self.decodeInt(dict, key: "pkStatus")
        self.diamondGiftActive = Self.decodeInt(dict, key: "diamondGiftActive")
    }

    /// 数值字段 String/Int 双兼容 decoder（对齐 userId / joinNum 同款 pattern）。
    /// - NSNumber Bool 桥接（objCType "c"/"B"）返 nil，避免 true/false 被误认为 1/0
    /// - String 走 `Int(_:)`，非数字字符串返 nil
    private static func decodeInt(_ dict: [String: Any], key: String) -> Int? {
        if let n = dict[key] as? NSNumber {
            let cType = String(cString: n.objCType)
            if cType == "c" || cType == "B" { return nil }
            return n.intValue
        }
        if let s = dict[key] as? String {
            return Int(s)
        }
        return nil
    }
}

// MARK: - 状态机

/// 广场加载态。照搬 LiveList / Blocklist 的 4 态机（idle / loadingFirstPage / loadingMore / loaded / error）。
enum LiveStreamLoadState: Equatable {
    case idle
    case loadingFirstPage
    case loadingMore
    case loaded
    case error(String)

    var isLoading: Bool {
        switch self {
        case .loadingFirstPage, .loadingMore: return true
        default: return false
        }
    }

    var errorMessage: String? {
        if case .error(let m) = self { return m }
        return nil
    }
}

// MARK: - Service protocol

/// Live 广场数据层协议——真集成走 `LiveStreamService.shared`，单测注入 Fake。
protocol LiveStreamServiceProtocol {
    /// 拉一页广场卡片。
    /// - parameter currentPage: 1-based 页码
    /// - parameter pageSize: 单页条数（H5 写 20）
    func fetchLiveList(currentPage: Int, pageSize: Int) async throws -> [LiveStreamAnchor]
}
