import Foundation

/// L 里程碑：视频匹配 Match 数据契约。对齐 H5 `src/api/match/type.ts` + `home/match.vue` + `c-goMatch.vue`。
/// 详见 `docs/plan/L-spec-视频匹配Match-*.md` §3.2。

// MARK: - /api/anchor/getMatchPoolData 响应

/// Match tab 首屏数据（跑马灯 + 用户列表）。对应 H5 `getMatchRecordList` 返回结构。
struct MatchPoolData: Decodable {
    let callList: [MatchCallRecord]
    let userList: [MatchUserItem]

    // callList / userList 后端可能返 null，需 fallback 空数组
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        callList = (try? c.decode([MatchCallRecord].self, forKey: .callList)) ?? []
        userList = (try? c.decode([MatchUserItem].self, forKey: .userList)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case callList, userList }
}

/// 跑马灯项：其他主播的通话记录（对方 → 主播的匹配接通）。
struct MatchCallRecord: Decodable, Identifiable, Equatable {
    let callerIcon: String
    let callerNickname: String
    let receiverIcon: String
    let receiverNickname: String

    /// Identifiable：跑马灯滚动动画需要稳定 id。以 caller+receiver 昵称拼接兜底（接口无 id 字段）。
    var id: String { "\(callerNickname)-\(receiverNickname)-\(callerIcon.hashValue)" }
}

/// 匹配用户卡片：Match tab 底部用户列表项 + 用户详情弹窗数据。
///
/// 对齐 H5 `MatchUserData`（`src/api/match/type.ts`），字段偏移不复用 LiveListAnchor（v3 RA17）。
struct MatchUserItem: Decodable, Identifiable, Equatable {
    /// **String/Int 双兼容**：H5 type.ts 声明 userId=number，但后端可能返 String（沿用
    /// `.claude/rules/ios-decode-userid-compat.md` 铁律）。统一收为 String。
    let userId: String
    let nickname: String
    let icon: String
    let age: Int?
    let gender: Int?
    let vip: Int?
    let userLevel: Int?
    let videoPrice: Int?
    /// 是否可拨打（对齐 H5 canCall；0=不可 / 1=可）
    let canCall: Int?
    /// 是否免费（对齐 H5 free；0=计费 / 1=免费）
    let free: Int?
    let userType: Int?

    var id: String { userId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // userId String/Int 双兼容
        if let s = try? c.decode(String.self, forKey: .userId), !s.isEmpty {
            userId = s
        } else if let i = try? c.decode(Int64.self, forKey: .userId) {
            userId = String(i)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .userId, in: c,
                debugDescription: "userId neither String nor Int64"
            )
        }
        nickname = (try? c.decode(String.self, forKey: .nickname)) ?? ""
        icon = (try? c.decode(String.self, forKey: .icon)) ?? ""
        age = try? c.decode(Int.self, forKey: .age)
        gender = try? c.decode(Int.self, forKey: .gender)
        vip = try? c.decode(Int.self, forKey: .vip)
        userLevel = try? c.decode(Int.self, forKey: .userLevel)
        videoPrice = try? c.decode(Int.self, forKey: .videoPrice)
        canCall = try? c.decode(Int.self, forKey: .canCall)
        free = try? c.decode(Int.self, forKey: .free)
        userType = try? c.decode(Int.self, forKey: .userType)
    }

    private enum CodingKeys: String, CodingKey {
        case userId, nickname, icon, age, gender, vip, userLevel, videoPrice, canCall, free, userType
    }
}

extension MatchUserItem {
    /// SwiftUI Preview / 单测便利构造器（Codable 自定义 init 后 memberwise init 不自动生成）。
    static func previewFixture(
        userId: String = "1",
        nickname: String = "Preview",
        icon: String = "",
        age: Int? = nil,
        gender: Int? = nil,
        vip: Int? = nil,
        userLevel: Int? = nil,
        videoPrice: Int? = nil,
        canCall: Int? = nil,
        free: Int? = nil,
        userType: Int? = nil
    ) -> MatchUserItem {
        // 通过 Codable 反向构造：写 JSON 再 decode，避免 stored properties 外部赋值限制
        var dict: [String: Any] = [
            "userId": userId, "nickname": nickname, "icon": icon,
        ]
        if let v = age { dict["age"] = v }
        if let v = gender { dict["gender"] = v }
        if let v = vip { dict["vip"] = v }
        if let v = userLevel { dict["userLevel"] = v }
        if let v = videoPrice { dict["videoPrice"] = v }
        if let v = canCall { dict["canCall"] = v }
        if let v = free { dict["free"] = v }
        if let v = userType { dict["userType"] = v }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(MatchUserItem.self, from: data)
    }
}

// MARK: - /api/match/pool/matchList 响应（分页）

/// 匹配池用户列表分页响应。H5 声明 `Pagination` 参数 pageNum + pageSize；
/// 返回结构 H5 是 `http.post<any[]>` —— **本 spec §7 open #2 待 step 1c grep 校验**。
///
/// 假设：后端返回直接的 `[MatchUserItem]` 数组（对齐 H5 `<any[]>`）。若返回带 total/hasMore 需修正。
typealias MatchListPage = [MatchUserItem]

// MARK: - /api/match/pool/isOpen 结果

/// 匹配开启前置校验结果。对应 `getMatchCanOpen` 返回的 Int 值。
enum MatchCanOpenResult: Int, Equatable {
    case allowed = 1            // 可开启
    case faceCheckFailed = 2    // 人脸识别失败（封禁）
    case exceededCount = 3      // 超过次数（封禁）
}

// MARK: - /api/match/pool/open 请求

/// toggleMatch 请求体。对齐 H5 `c-goMatch.vue` handleToggleMatch({ status, faceCheckStatus? })。
struct ToggleMatchRequest: Encodable {
    /// 1=开启 / 0=关闭
    let status: Int
    /// 仅在人脸检测失败关匹配时上报（faceCheckStatus=1）。
    /// H5 `closeMatch:365` `userStore.isMatchBlocked ? 1 : undefined` —— MVP 阶段人脸抽检未做，恒 nil。
    let faceCheckStatus: Int?
}
