import Foundation

/// 麦位 anchorTaskRewardExt 嵌套字段（主播任务奖励配置）。MVP 不消费，仅保留解码兼容。
struct PartyAnchorTaskRewardExt: Codable, Equatable {
    let vfxUrl: String?
    let icon: String?
    let itemId: String?
    let bgImgId: String?
}

/// 派对房麦位（v3 真值版，按 dev `seat/list` 返回 schema 重构于 2026-06-24）。
///
/// 字段语义对照 dev 实测：
/// - `seatType`：1=视频位 / 2=语聊位
/// - `isOccupied`：**Int 0/1**（后端用 0/1 不是 Bool）
/// - `microphoneEnabled / cameraEnabled`：**用户自身**麦克风/摄像头开关
/// - `seatMicrophoneEnabled / seatCameraEnabled`：**管理员**禁麦/禁摄像头态（独立于自身开关）
/// - `roomRoleType`：坐麦人角色（1=房主 2=房管 3=观众）
/// - `yxAccid`：云信 accid，**送礼用**（gift/sendGift 入参 yxAccidList 用这个字段，非 userId）
/// - `anchorTaskRewardExt`：主播任务奖励（vfxUrl/icon/itemId/bgImgId 含特效配置），MVP 不消费
///
/// 全字段 Optional 容错。
struct PartyRoomSeat: Codable, Equatable, Identifiable {
    let id: String?                       // 麦位记录主键（数据库 ID，非业务）
    let roomId: String?                   // 冗余房间 ID
    let seatIndex: Int?
    let userId: String?
    let avatar: String?
    let nickname: String?
    let seatType: Int?                    // 1=video 2=voice
    let isOccupied: Int?                  // 0=空 1=有人（后端用 Int 不是 Bool）
    let cameraEnabled: Int?               // 用户自身摄像头
    let microphoneEnabled: Int?           // 用户自身麦克风
    let roomRoleType: Int?                // 1=owner 2=admin 3=audience
    /// 累计收礼值（钻石累计）。⚠️ dev 实测后端返 **Double**（如 4.2；H5 video-seat-cell.vue:28 注释"最多保留 2 位小数"），
    /// 非 Int；按 [ios-decode-userid-compat.md] rule 保留 Double? + 派生 Int（PartyNumberFormat.compact 用整数即可，小数精度 F 期再补 formatDiamond）
    let giftValueCount: Double?
    let headFrame: String?
    let yxAccid: String?                  // 云信 accid（送礼用）
    let userType: Int?
    let seatCameraEnabled: Int?           // 管理员禁摄像头态
    let seatMicrophoneEnabled: Int?       // 管理员禁麦态
    let lockFlag: Int?
    let roomTempId: String?               // 模板 ID 冗余
    /// MC Seat 标志（0=非 MC / 1=是 MC）；后端真机字段名未验证，用 CodingKeys alias 兜底
    /// hostSeat / isMcSeat / mcHost / hostFlag（[agent-recon-field-names-unverified] rule）
    let isHostSeat: Int?
    let isPlatformAdmin: Int?
    let showBubble: Bool?
    let anchorTaskRewardExt: PartyAnchorTaskRewardExt?

    /// CodingKeys —— isHostSeat 字段真机 log 未验证，用主键 `isHostSeat` + 4 别名候选（decode
    /// 时 KeyedDecodingContainer 只按声明的 case 匹配 key，本 enum 覆盖所有可能变体）
    enum CodingKeys: String, CodingKey {
        case id, roomId, seatIndex, userId, avatar, nickname
        case seatType, isOccupied, cameraEnabled, microphoneEnabled, roomRoleType
        case giftValueCount, headFrame, yxAccid, userType
        case seatCameraEnabled, seatMicrophoneEnabled, lockFlag, roomTempId
        case isHostSeat
        case isPlatformAdmin, showBubble, anchorTaskRewardExt
    }

    /// Memberwise init —— Swift 规则：一旦声明自定义 `init(from decoder:)`，编译器不再合成默认 memberwise
    /// init；`PartyStore` 里 seat 重构（麦位状态就地更新）依赖 memberwise 构造，因此必须手动补一份。
    init(
        id: String?,
        roomId: String?,
        seatIndex: Int?,
        userId: String?,
        avatar: String?,
        nickname: String?,
        seatType: Int?,
        isOccupied: Int?,
        cameraEnabled: Int?,
        microphoneEnabled: Int?,
        roomRoleType: Int?,
        giftValueCount: Double?,
        headFrame: String?,
        yxAccid: String?,
        userType: Int?,
        seatCameraEnabled: Int?,
        seatMicrophoneEnabled: Int?,
        lockFlag: Int?,
        roomTempId: String?,
        isHostSeat: Int?,
        isPlatformAdmin: Int?,
        showBubble: Bool?,
        anchorTaskRewardExt: PartyAnchorTaskRewardExt?
    ) {
        self.id = id
        self.roomId = roomId
        self.seatIndex = seatIndex
        self.userId = userId
        self.avatar = avatar
        self.nickname = nickname
        self.seatType = seatType
        self.isOccupied = isOccupied
        self.cameraEnabled = cameraEnabled
        self.microphoneEnabled = microphoneEnabled
        self.roomRoleType = roomRoleType
        self.giftValueCount = giftValueCount
        self.headFrame = headFrame
        self.yxAccid = yxAccid
        self.userType = userType
        self.seatCameraEnabled = seatCameraEnabled
        self.seatMicrophoneEnabled = seatMicrophoneEnabled
        self.lockFlag = lockFlag
        self.roomTempId = roomTempId
        self.isHostSeat = isHostSeat
        self.isPlatformAdmin = isPlatformAdmin
        self.showBubble = showBubble
        self.anchorTaskRewardExt = anchorTaskRewardExt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // id / roomId / userId 都可能被后端返 Number（对齐 [ios-decode-userid-compat.md] rule）
        // 严格 String decode 会 fail-loud 静默返回 nil → Bridge filter 命中 → 礼物面板收礼人空
        // trial 修复：三个 ID 字段一律走 String/Int64 双兼容
        id = Self.decodeIdString(c, key: .id)
        roomId = Self.decodeIdString(c, key: .roomId)
        seatIndex = try? c.decode(Int.self, forKey: .seatIndex)
        userId = Self.decodeIdString(c, key: .userId)
        avatar = try? c.decode(String.self, forKey: .avatar)
        nickname = try? c.decode(String.self, forKey: .nickname)
        seatType = try? c.decode(Int.self, forKey: .seatType)
        isOccupied = try? c.decode(Int.self, forKey: .isOccupied)
        cameraEnabled = try? c.decode(Int.self, forKey: .cameraEnabled)
        microphoneEnabled = try? c.decode(Int.self, forKey: .microphoneEnabled)
        roomRoleType = try? c.decode(Int.self, forKey: .roomRoleType)
        giftValueCount = try? c.decode(Double.self, forKey: .giftValueCount)
        headFrame = try? c.decode(String.self, forKey: .headFrame)
        yxAccid = try? c.decode(String.self, forKey: .yxAccid)
        userType = try? c.decode(Int.self, forKey: .userType)
        seatCameraEnabled = try? c.decode(Int.self, forKey: .seatCameraEnabled)
        seatMicrophoneEnabled = try? c.decode(Int.self, forKey: .seatMicrophoneEnabled)
        lockFlag = try? c.decode(Int.self, forKey: .lockFlag)
        roomTempId = try? c.decode(String.self, forKey: .roomTempId)
        isHostSeat = Self.decodeIsHostSeat(c)
        isPlatformAdmin = try? c.decode(Int.self, forKey: .isPlatformAdmin)
        showBubble = try? c.decode(Bool.self, forKey: .showBubble)
        anchorTaskRewardExt = try? c.decode(PartyAnchorTaskRewardExt.self, forKey: .anchorTaskRewardExt)
    }

    /// ID 字段 String/Int64 双兼容 decode（对齐 [ios-decode-userid-compat.md] rule §Decoder 模板）
    /// 后端可能返 String 或 Number；严格 `decode(String.self)` 遇 Number 会 fail-loud 静默返 nil。
    /// - Bool 桥接排除：NSNumber objCType "c"/"B" = Bool，避免 `1.stringValue = "1"` 但语义错的场景
    private static func decodeIdString(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> String? {
        if let s = try? c.decode(String.self, forKey: key), !s.isEmpty { return s }
        if let n = try? c.decode(Int64.self, forKey: key) { return String(n) }
        return nil
    }

    /// isHostSeat 字段真机未验证；用双 container 尝试 alias 兜底
    private static func decodeIsHostSeat(_ c: KeyedDecodingContainer<CodingKeys>) -> Int? {
        if let v = try? c.decode(Int.self, forKey: .isHostSeat) { return v }
        // 尝试 String→Int 双兼容（后端可能返 "0"/"1"）
        if let s = try? c.decode(String.self, forKey: .isHostSeat), let v = Int(s) { return v }
        // Fallback alias（CodingKeys 之外的候选，用 AnyKey container）
        struct AnyKey: CodingKey {
            let stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }
        guard let alt = try? c.superDecoder().container(keyedBy: AnyKey.self) else { return nil }
        for name in ["hostSeat", "isMcSeat", "isMCSeat", "mcHost", "hostFlag"] {
            guard let key = AnyKey(stringValue: name) else { continue }
            if let v = try? alt.decode(Int.self, forKey: key) { return v }
            if let s = try? alt.decode(String.self, forKey: key), let v = Int(s) { return v }
        }
        return nil
    }

    /// 是否被有效占用（双判：占位字段 + userId 任一）
    var occupied: Bool {
        if (isOccupied ?? 0) == 1 { return true }
        return !(userId?.isEmpty ?? true)
    }

    /// 强类型 seatType（未知值 nil 不参与对账分支）
    var typed: PartyRoomSeatType? {
        guard let s = seatType else { return nil }
        return PartyRoomSeatType(rawValue: s)
    }

    /// 强类型角色
    var typedRole: PartyRoomRoleType? {
        guard let r = roomRoleType else { return nil }
        return PartyRoomRoleType(rawValue: r)
    }

    /// 衍生：giftValueCount Int 形式（PartyNumberFormat.compact(Int) 用；小数丢弃，F 期补 formatDiamond 2 位小数）
    var giftValueCountInt: Int { Int(giftValueCount ?? 0) }

    /// SwiftUI ForEach 用稳定 Identity（review 202606252033 P1-5）。
    /// `id` 是数据库主键 String? 可能 nil；多个 nil 会让 ForEach Identity 坍缩 → PartyRemoteVideoView 误调 dismantle → 远端视频黑屏。
    /// 改用业务键 seatIndex（麦位 1-13 唯一），nil 退化到 -1（极端情况，不影响生产）。
    var stableId: Int { seatIndex ?? -1 }
}
