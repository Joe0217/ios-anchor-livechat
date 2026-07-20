import Foundation

/// 通话历史记录 model —— 对齐 H5 `views/communication/records/list.vue` 展示字段
/// 后端字面：`POST /api/chat/v4/getCallRecord`（[src/api/news/index.ts:5](anchor-livechat-h5/src/api/news/index.ts)）。
///
/// H5 使用位置：`views/communication/index.vue:apiGetRecordList` +
/// `views/communication/records/list.vue` 逐字段消费。
///
/// **字段来源为 H5 源码字面消费**，未来若首次真机 log 揭露字段名不一致，
/// 按 [agent-recon-field-names-unverified.md](../../.claude/rules/agent-recon-field-names-unverified.md)
/// 加 CodingKeys 别名兜底。
struct CallRecord: Identifiable, Equatable {

    /// 用户业务 id（一律 String —— 后端 String/Int 混发，参 [ios-decode-userid-compat.md](../../.claude/rules/ios-decode-userid-compat.md)）
    let userId: String
    /// 云信 accid（进私聊页 push 用）
    let yxAccid: String?
    /// 头像 URL
    let icon: String?
    /// 昵称
    let nickname: String
    /// 用户等级名（H5 用 "0" 表示无等级 / "35" 表示 35 级；nil/空/"0" 均视为无）
    let userLevelName: String?
    /// VIP 到期时间戳（ms）。> now 视为有效 VIP
    let vipExpireTime: Int64
    /// 通话来源
    let source: CallRecordSource
    /// 是否接通 + 未接原因
    let missedReason: CallMissedReason
    /// 呼入 or 呼出
    let direction: CallDirection
    /// 通话时长（秒）
    let duration: Int
    /// 通话开始时间（ms）
    let createTime: Int64

    var id: String { "\(createTime)-\(userId)" }

    var isSuccess: Bool { missedReason == .success }

    /// H5 VIP 有效判定：H5 `vipExpireTime > new Date().getTime()`
    var isVIPActive: Bool {
        vipExpireTime > Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// H5 等级 badge 展示条件：`userLevelName && userLevelName !== '0'`
    var showsLevelBadge: Bool {
        guard let n = userLevelName, !n.isEmpty else { return false }
        return n != "0"
    }
}

/// 通话来源 —— H5 `list.vue:source()` 三分档
enum CallRecordSource: String {
    /// 匹配呼叫（`matchV4` → "Match" 粉色）
    case match = "matchV4"
    /// 直播中呼叫（`liveCall` → "Live" 橙色）
    case liveCall = "liveCall"
    /// 其他（含 `private` 等 → "Private" 紫色）
    case privateCall

    init(raw: String?) {
        switch raw {
        case "matchV4":  self = .match
        case "liveCall": self = .liveCall
        default:         self = .privateCall
        }
    }
}

/// 通话未接原因 —— H5 `list.vue:missedReason()` 三档 + 接通态
enum CallMissedReason: Equatable {
    /// 接通（H5：missedReason == 4）
    case success
    /// 拒接（H5：missedReason == 1 → "Rejected"）
    case rejected
    /// 超时（H5：missedReason == 2 → "Timeout"）
    case timeout
    /// 取消（H5：其他 → "Canceled"；含 undefined）
    case canceled

    init(raw: Int?) {
        switch raw {
        case 4:  self = .success
        case 1:  self = .rejected
        case 2:  self = .timeout
        default: self = .canceled
        }
    }
}

/// 呼入 / 呼出 —— H5 `callerUserType`：1 或 空为呼入（用户拨给主播），其他为呼出
enum CallDirection {
    /// 呼入（用户 → 主播；callerUserType == 1 或 nil / 0）
    case incoming
    /// 呼出（主播 → 用户）
    case outgoing

    init(callerUserType: Int?) {
        // H5 逻辑：`!item.callerUserType || item.callerUserType === 1` → 呼入
        if callerUserType == nil || callerUserType == 0 || callerUserType == 1 {
            self = .incoming
        } else {
            self = .outgoing
        }
    }
}

// MARK: - Decoding

extension CallRecord: Decodable {

    enum CodingKeys: String, CodingKey {
        case userId, yxAccid, icon, nickname, userLevelName, vipExpireTime
        case source, missedReason, callerUserType, duration, createTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // userId：H5 type 声明 string，实际 String/Int 混发。参 ios-decode-userid-compat rule
        if let s = try? c.decode(String.self, forKey: .userId), !s.isEmpty {
            self.userId = s
        } else if let i = try? c.decode(Int64.self, forKey: .userId) {
            self.userId = String(i)
        } else {
            self.userId = ""
        }

        // yxAccid：一般 String，Int 兜底
        if let s = try? c.decode(String.self, forKey: .yxAccid), !s.isEmpty {
            self.yxAccid = s
        } else if let i = try? c.decode(Int64.self, forKey: .yxAccid) {
            self.yxAccid = String(i)
        } else {
            self.yxAccid = nil
        }

        self.icon = try? c.decode(String.self, forKey: .icon)
        self.nickname = (try? c.decode(String.self, forKey: .nickname)) ?? ""
        self.userLevelName = try? c.decode(String.self, forKey: .userLevelName)

        // vipExpireTime：ms 时间戳 Int64；缺省或 0 视为无 VIP
        self.vipExpireTime = (try? c.decode(Int64.self, forKey: .vipExpireTime)) ?? 0

        // source / missedReason / callerUserType：包装到语义 enum
        let sourceRaw = try? c.decode(String.self, forKey: .source)
        self.source = CallRecordSource(raw: sourceRaw)

        let missedRaw = try? c.decode(Int.self, forKey: .missedReason)
        self.missedReason = CallMissedReason(raw: missedRaw)

        let callerRaw = try? c.decode(Int.self, forKey: .callerUserType)
        self.direction = CallDirection(callerUserType: callerRaw)

        self.duration = (try? c.decode(Int.self, forKey: .duration)) ?? 0
        self.createTime = (try? c.decode(Int64.self, forKey: .createTime)) ?? 0
    }
}
