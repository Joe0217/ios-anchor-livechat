import Foundation

/// 派对房列表内嵌的在线用户预览（observer/麦上混合，list 接口最多前 N 条）。
struct PartyOnlineUser: Codable, Equatable {
    let userId: String?
    let avatar: String?
    let nickname: String?
}

/// 派对房房间信息（v3 真值版，按 dev `room/list` 返回 schema 重构于 2026-06-24）。
///
/// 三 ID 解耦（spec §1.1）：
/// - `id`：业务 roomId
/// - `agoraChannelId`：声网频道
/// - `yxRoomId`：云信 NIM 聊天室
///
/// 注意：
/// - **`roomTempId` 是 String**（dev 真实返回 `"1"`）；调用 seat 接口时直接转发字符串
/// - **`onlineCount` 衍生自 `onlineUserList.count`**，后端 list 接口不直接返"在线人数"，`heatValue` 是热度分非人数
/// - `seatList / rtcToken` 仅 `room/enter` 接口才返；list 接口缺失
/// - 全字段 Optional 容错，后端新增字段不会让现有解码崩
struct PartyRoomInfo: Codable, Equatable {
    let id: String?
    let ownerId: String?
    /// 自己在本房的角色（仅 `room/enter` 接口返；list 不返）：1=房主 2=房管 3=普通
    /// 来源：`EnterRoomResponse.roomRoleType`（安卓确认 §2.1）
    let roomRoleType: Int?
    /// 平台管理员标志（仅 `room/enter` 返）；与角色独立，权限最高
    let isPlatformAdmin: Bool?
    // 注：`roomAdminCount` 后端实际返 String（dev 实测 "0"，与安卓确认文档 Long 标注不符）；
    // MVP 不消费此字段，直接省略避免类型解码失败。F 期如需要房管管理 UI 再添加 String? 字段
    let roomName: String?
    let roomAvatar: String?
    let greetingMessage: String?
    /// 房间公告。与房间引导语 `greetingMessage` 独立，修改后服务端会广播 1049 公屏消息。
    var announcement: String? = nil
    let roomLanguage: String?
    let heatValue: Int?              // 房间热度分（非在线人数）
    let roomStatus: Int?             // 1=开放 / 2=关闭（具体语义实测确认）
    let lockFlag: Int?               // 0=未锁 1=有密码
    let yxRoomId: String?
    let agoraChannelId: String?
    let rtcToken: String?            // 仅 room/enter 返
    let onlineUserList: [PartyOnlineUser]?
    let score: String?
    let createTime: String?
    let needPassword: Bool?
    let snapshotId: String?
    let roomTempId: String?          // ⚠️ String 不是 Int（dev 返 "1"）
    let roomTempType: Int?
    let rangIndex: Int?
    let showChest: Bool?
    let gemsTotal: Int?
    /// Party 房 Weekly Task 达标奖励宝石数；安卓仅在该值大于 0 时展示入口。
    ///
    /// `room/enter` 是跨端 DTO，数值字段在不同环境可能以 JSON number 或字符串返回。
    /// 该字段只控制附加入口，不能因类型漂移导致整个进房响应解码失败。
    @PartyFlexibleInt var rewardQuantity: Int? = nil
    let pkStatus: Int?
    let pkId: String?
    /// 房间关注态（对齐 H5 `currentPartyInfo.isFollowOwner`；仅 `room/enter` 接口返）。
    /// `nil` 视为未关注（保守 fallback）。
    let isFollowOwner: Bool?
    /// 财富榜当日累计贡献值（对齐 H5 `currentPartyInfo.contributionCostNum`；房内顶部统计条轮播 1）。
    /// ⚠️ dev 实测后端返 **String**（`"0"`），非 Int；按 [ios-decode-userid-compat.md] rule 保留 String? + 派生 Int。
    let contributionCostNum: String?
    /// 荣耀榜当日累计荣耀值（对齐 H5 `currentPartyInfo.honorDailyTotal`；房内顶部统计条轮播 2）。
    /// ⚠️ dev 实测后端返 **String**（`"0"`），非 Int；同上策略。
    let honorDailyTotal: String?
    /// 观众数（对齐 H5 `currentPartyInfo.audienceNum`；独立于 `onlineUserList.count`——
    /// 后者是预览用户前 N 条，前者是真实观众总数）
    let audienceNum: Int?
    /// 麦位列表（dev 实测 `room/enter` 接口返字段名是 `roomSeatList`，与 spec 反推的 seatList 不符）；
    /// `room/list` 不返麦位列表。
    let roomSeatList: [PartyRoomSeat]?
    /// v16：房间背景缩略图 URL（房主设置的自定义背景；null = 用默认 partyRoomBg）
    let bgImgUrl: String?
    /// v16：房间背景大图 URL（H5 room-bg.vue 优先用；对齐 backgroundLayer 视觉）
    let bigImgUrl: String?

    /// F 期私 call 开关（房间级）；1=开 / 0=关；`nil` fallback 0（保守）。
    /// 后端 `room/enter` 响应字段。房主通过 `updatePartyPrivateCall` 修改。
    /// 真实字段名待 Step 3 真机 log 校准（预估基于安卓源码梳理 §3 + PartyRoomInfo.kt:77）
    let partyPrivateCallOpen: Int?
    /// F 期私 call 礼物 id；用户端拨打时预扣此礼物。
    let partyCallGiftId: String?
    /// F 期私 call 礼物图片 URL（后端 `room/enter` 直接返；用户端拨打时预扣此礼物的展示图）。
    /// **关键**：这是后端 enterRoom 响应字段，不用二次调 `getPartyCallGiftList` 匹配。
    let partyCallGiftImg: String?
    /// F 期私 call 礼物价格（蓝钻数量）；后端 `room/enter` 直接返 Int。
    let partyCallGiftPrice: Int?

    /// 排麦申请模式开关（房间级）；`true` 表示需要走"申请上麦"流程。对齐安卓 `PartyRoomInfo.onSeatApplySwitch`。
    /// 后端 `room/enter` 响应字段；进房后 UI 分流依赖此字段初始态（1021 广播只在切换时才下发）。
    /// 字段名来自安卓源码梳理（未真机 log 校准）：参 [agent-recon-field-names-unverified] rule，
    /// 真机验证 raw JSON 后如后端字段名不同，此处补 CodingKeys alias。
    let onSeatApplySwitch: Bool?

    /// 房间音乐功能总开关。H5 仍使用后端历史拼写 `roomMusicSwitc`；0/nil 时不显示管理入口。
    let roomMusicSwitc: Int?

    /// 进房响应下发的 Party 右上角活动资源位；顶部展示时只消费第一条。
    /// 使用 `var` 以保留合成 memberwise initializer 的默认参数；`withUpdated` 必须原样带回该字段。
    var cornerBannerList: [PartyCornerBanner]? = nil

    /// 进房响应下发的右下角活动轮播资源位。与顶部 `cornerBannerList` 是两个独立位置，
    /// 仅在完整 Party 房舞台内消费。
    var bannerList: [PartyRoomBanner]? = nil

    /// 排麦队列长度（房间级 badge 数值）；对齐安卓 `PartyRoomInfo.queueSeatNum: Long`。
    /// 后端 `room/enter` 响应字段；进房时同步到 `PartyStore.queueSeatNum` 让 AnchorBar / Tools sheet
    /// badge 立即显示已有排队数（否则要等下一次 1018 到达才 refresh）。
    let queueSeatNum: Int?

    /// 衍生：观众在线人数（用 `onlineUserList.count`；list 接口无独立人数字段）
    var onlineCount: Int { onlineUserList?.count ?? 0 }

    /// 衍生：私 call 是否开启（房主视角）。`partyPrivateCallOpen == 1`。
    /// 用于 CallStore.handleIncomingVideoCall 派对分支前置 guard（对齐 LiveStore.privateCallOpen · P1-9）
    var isPartyPrivateCallEnabled: Bool { partyPrivateCallOpen == 1 }

    var isRoomMusicAvailable: Bool { (roomMusicSwitc ?? 0) != 0 }

    /// 衍生：roomTempId Int 形式（后端 DTO 是 Long，但 HTTP 响应给字符串；调上下麦/respondInvite 时需 Int）。
    /// fallback 1（dev 主流模板 ID）；若 String 不可解析为 Int 同样退化到 1。
    var roomTempIdInt: Int { Int(roomTempId ?? "") ?? 1 }

    /// 衍生：贡献值 Int 形式（UI 用 PartyNumberFormat.compact(Int) 显示）；fallback 0。
    var contributionCostNumInt: Int { Int(contributionCostNum ?? "") ?? 0 }

    /// 衍生：荣耀值 Int 形式（UI 同上）；fallback 0。
    var honorDailyTotalInt: Int { Int(honorDailyTotal ?? "") ?? 0 }

    /// SwiftUI ForEach 用稳定 Identity（review 202606252033 P1-5）。
    /// `id` 是 String? 可能 nil；多个 nil 同 Identity 会让 ForEach diff 错乱。
    /// 多重 fallback：id → agoraChannelId → yxRoomId → ownerId → roomName → "unknown"；
    /// 加前缀防同串值在不同字段域互相串扰（例：id="x" vs ownerId="x" 视作不同 identity）。
    var stableListId: String {
        if let v = id, !v.isEmpty { return "id_\(v)" }
        if let v = agoraChannelId, !v.isEmpty { return "ch_\(v)" }
        if let v = yxRoomId, !v.isEmpty { return "yx_\(v)" }
        if let v = ownerId, !v.isEmpty { return "ow_\(v)" }
        if let v = roomName, !v.isEmpty { return "nm_\(v)" }
        return "unknown"
    }

    /// 衍生：自己角色（信服务端字段，不再用 `ownerId==myUserId` 推断 —— 安卓确认 §4.2 反例：
    /// 房管/平台管理员都不是房主但有管理权限，纯 ownerId 比较会漏判）。
    /// 顺序：
    /// 1) `isPlatformAdmin==true` → **提权等同房主**（对齐 H5 `computedRoomRoleType` usePartyHooks.js:31-35 +
    ///    安卓 `PartyRoomActivity.kt:893-898` `isPlatformAdmin || OWNER` 判定；差异文档 §4 明示）
    /// 2) `roomRoleType` 服务端字段（1/2/3 → owner/admin/audience）
    /// 3) fallback：`ownerId==myUserId` → owner（仅在 list 接口无 roomRoleType 字段时用）
    /// `myUserId` 参数保留为 fallback 路径用
    func selfRoleType(myUserId: String?) -> PartyRoomRoleType {
        if isPlatformAdmin == true { return .owner }  // 提权等同房主（非 admin）
        if let raw = roomRoleType, let role = PartyRoomRoleType(rawValue: raw) {
            return role
        }
        // fallback（仅 list 接口无 roomRoleType 时用）
        guard let me = myUserId, !me.isEmpty,
              let owner = ownerId, !owner.isEmpty else {
            return .audience
        }
        return owner == me ? .owner : .audience
    }

    /// 房主保存设置后回写字段（其他字段保留）。传 nil 表示不改；传新值覆盖。
    /// SwiftUI Store 侧用：`store.roomInfo = info.withUpdated(...)`
    ///
    /// v2（2026-07-14）追加 `roomTempId` 参数——E spec §1 Room Mode 切模板成功后，
    /// PartyStore.handleRoomModeChanged 需回写 `roomInfo.roomTempId` 让下次 IM 幂等判断能命中
    /// （否则 `roomTempId==newTempId` 幂等保护恒为 false，重复触发下麦 hook）。
    ///
    /// v3（2026-07-14）追加 `lockFlag` / `needPassword`——E spec §3 Lock Room 加/解锁后
    /// PartyStore 本地乐观更新（无 IM 广播），下次 refresh 前用回写字段驱动 UI 立即反馈。
    func withUpdated(
        roomRoleType: Int? = nil,
        roomName: String? = nil,
        roomAvatar: String? = nil,
        greetingMessage: String? = nil,
        announcement: String? = nil,
        roomLanguage: String? = nil,
        roomTempId: String? = nil,
        lockFlag: Int? = nil,
        needPassword: Bool? = nil,
        partyPrivateCallOpen: Int? = nil,
        partyCallGiftId: String? = nil,
        partyCallGiftImg: String? = nil,
        partyCallGiftPrice: Int? = nil,
        onSeatApplySwitch: Bool? = nil,
        roomMusicSwitc: Int? = nil,
        contributionCostNum: String? = nil,
        queueSeatNum: Int? = nil
    ) -> PartyRoomInfo {
        PartyRoomInfo(
            id: id,
            ownerId: ownerId,
            roomRoleType: roomRoleType ?? self.roomRoleType,
            isPlatformAdmin: isPlatformAdmin,
            roomName: roomName ?? self.roomName,
            roomAvatar: roomAvatar ?? self.roomAvatar,
            greetingMessage: greetingMessage ?? self.greetingMessage,
            announcement: announcement ?? self.announcement,
            roomLanguage: roomLanguage ?? self.roomLanguage,
            heatValue: heatValue,
            roomStatus: roomStatus,
            lockFlag: lockFlag ?? self.lockFlag,
            yxRoomId: yxRoomId,
            agoraChannelId: agoraChannelId,
            rtcToken: rtcToken,
            onlineUserList: onlineUserList,
            score: score,
            createTime: createTime,
            needPassword: needPassword ?? self.needPassword,
            snapshotId: snapshotId,
            roomTempId: roomTempId ?? self.roomTempId,
            roomTempType: roomTempType,
            rangIndex: rangIndex,
            showChest: showChest,
            gemsTotal: gemsTotal,
            rewardQuantity: rewardQuantity,
            pkStatus: pkStatus,
            pkId: pkId,
            isFollowOwner: isFollowOwner,
            contributionCostNum: contributionCostNum ?? self.contributionCostNum,
            honorDailyTotal: honorDailyTotal,
            audienceNum: audienceNum,
            roomSeatList: roomSeatList,
            bgImgUrl: bgImgUrl,
            bigImgUrl: bigImgUrl,
            partyPrivateCallOpen: partyPrivateCallOpen ?? self.partyPrivateCallOpen,
            partyCallGiftId: partyCallGiftId ?? self.partyCallGiftId,
            partyCallGiftImg: partyCallGiftImg ?? self.partyCallGiftImg,
            partyCallGiftPrice: partyCallGiftPrice ?? self.partyCallGiftPrice,
            onSeatApplySwitch: onSeatApplySwitch ?? self.onSeatApplySwitch,
            roomMusicSwitc: roomMusicSwitc ?? self.roomMusicSwitc,
            cornerBannerList: cornerBannerList,
            bannerList: bannerList,
            queueSeatNum: queueSeatNum ?? self.queueSeatNum
        )
    }
}

/// Party 房接口中可能为 number 或 string 的可选整数。
@propertyWrapper
struct PartyFlexibleInt: Codable, Equatable {
    var wrappedValue: Int?

    init(wrappedValue: Int? = nil) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard !container.decodeNil() else {
            wrappedValue = nil
            return
        }
        if let value = try? container.decode(Int.self) {
            wrappedValue = value
        } else if let value = try? container.decode(Int64.self),
                  let intValue = Int(exactly: value) {
            wrappedValue = intValue
        } else if let value = try? container.decode(String.self) {
            wrappedValue = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if let value = try? container.decode(Double.self),
                  let intValue = Int(exactly: value) {
            wrappedValue = intValue
        } else {
            wrappedValue = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(wrappedValue)
        } else {
            try container.encodeNil()
        }
    }
}

private extension KeyedDecodingContainer {
    func decode(_ type: PartyFlexibleInt.Type, forKey key: Key) throws -> PartyFlexibleInt {
        try decodeIfPresent(type, forKey: key) ?? PartyFlexibleInt()
    }
}

/// Party 房右下角活动轮播项。后端 `id` 在不同环境可能是 String 或 Number，需兼容解码。
struct PartyRoomBanner: Codable, Equatable {
    let id: String?
    let picUrl: String?
    let activityName: String?
    let name: String?
    let directUrl: String?
    let activityFlamePic: String?
    let flameStartTime: String?
    let flameEndTime: String?

    /// 图片是展示的唯一前置条件；缺跳转地址时仍保留展示，但不响应点击。
    var isDisplayable: Bool { picUrl?.isEmpty == false }
    var isNavigable: Bool { directUrl?.isEmpty == false }
    enum CodingKeys: String, CodingKey {
        case id, picUrl, activityName, name, directUrl, activityFlamePic, flameStartTime, flameEndTime
    }

    init(
        id: String? = nil,
        picUrl: String? = nil,
        activityName: String? = nil,
        name: String? = nil,
        directUrl: String? = nil,
        activityFlamePic: String? = nil,
        flameStartTime: String? = nil,
        flameEndTime: String? = nil
    ) {
        self.id = id
        self.picUrl = picUrl
        self.activityName = activityName
        self.name = name
        self.directUrl = directUrl
        self.activityFlamePic = activityFlamePic
        self.flameStartTime = flameStartTime
        self.flameEndTime = flameEndTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(String.self, forKey: .id) {
            id = value
        } else if let value = try? container.decode(Int64.self, forKey: .id) {
            id = String(value)
        } else {
            id = nil
        }
        picUrl = try? container.decode(String.self, forKey: .picUrl)
        activityName = try? container.decode(String.self, forKey: .activityName)
        name = try? container.decode(String.self, forKey: .name)
        directUrl = try? container.decode(String.self, forKey: .directUrl)
        activityFlamePic = try? container.decode(String.self, forKey: .activityFlamePic)
        flameStartTime = Self.decodeStringOrNumber(container, key: .flameStartTime)
        flameEndTime = Self.decodeStringOrNumber(container, key: .flameEndTime)
    }

    /// 时间字段后端可能返 ISO 日期或 epoch 数字，统一存成字符串交由展示层判断时间窗。
    private static func decodeStringOrNumber(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> String? {
        if let value = try? container.decode(String.self, forKey: key), !value.isEmpty { return value }
        if let value = try? container.decode(Int64.self, forKey: key) { return String(value) }
        if let value = try? container.decode(Double.self, forKey: key) { return String(Int64(value)) }
        return nil
    }
}

/// 主播端 Party 房右下角半屏游戏资源。
///
/// 数据来自 `/half/geme/anchor/list`；与用户端 `v2/list` 的游戏池不同。接口字段尚需首轮
/// 真机日志校验，因此使用字典解析兼容 `partyIcon` / `livePopIcon` 等已知资源字段。
struct PartyBannerGame: Identifiable, Equatable {
    let id: String
    let gameId: String
    let gameName: String?
    let partyIcon: String?
    let gameLink: String?
    let gameType: String?
    let appIds: String?

    var isDisplayable: Bool { partyIcon?.isEmpty == false }
    var isLaunchable: Bool { !gameId.isEmpty && gameLink?.isEmpty == false }
    /// 107 仅允许这类无付费、无奖品的房内互动；其他 H5 游戏仍需完整 Party 游戏权限。
    var isFreePartyInteraction: Bool {
        PartyFreeInteractionPolicy.allows(
            gameID: gameId,
            gameName: gameName,
            gameType: gameType
        )
    }

    static func decodeAnchorBannerGames(from data: Data) throws -> [PartyBannerGame] {
        let object = try JSONSerialization.jsonObject(with: data)
        let rows: [Any]
        if let array = object as? [Any] {
            rows = array
        } else if let root = object as? [String: Any],
                  let grouped = root["groupedGames"] as? [String: Any],
                  let games = grouped["8"] as? [Any] {
            // 用户端在 groupedGames[8] 取 Party Banner；主播端接口也优先兼容此包装。
            rows = games
        } else if let root = object as? [String: Any], let games = root["list"] as? [Any] {
            rows = games
        } else if let root = object as? [String: Any], let games = root["data"] as? [Any] {
            rows = games
        } else {
            rows = []
        }

        return rows.compactMap { row in
            guard let values = row as? [String: Any] else { return nil }
            return PartyBannerGame(values: values)
        }
    }

    private init?(values: [String: Any]) {
        let gameId = Self.stringValue(values["gameId"]) ?? ""
        let id = Self.stringValue(values["id"]) ?? gameId
        guard !id.isEmpty else { return nil }

        self.id = id
        self.gameId = gameId
        gameName = Self.stringValue(values["gameName"])
        partyIcon = Self.stringValue(values["partyIcon"])
            ?? Self.stringValue(values["livePopIcon"])
            ?? Self.stringValue(values["icon"])
        gameLink = Self.stringValue(values["gameLink"])
        gameType = Self.stringValue(values["gameType"])
        appIds = Self.stringValue(values["appIds"])
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber {
            let type = String(cString: value.objCType)
            if type != "c" && type != "B" { return value.stringValue }
        }
        return nil
    }
}

/// Party 免费互动的保守白名单。服务端下发的其他游戏即使带图标或链接，也不会因 107 放行。
enum PartyFreeInteractionPolicy {
    private static let allowedASCIIIdentifiers: Set<String> = [
        "rps",
        "rockpaperscissors",
        "dice",
    ]

    static func allows(gameID: String?, gameName: String?, gameType: String?) -> Bool {
        [gameID, gameName, gameType]
            .compactMap { $0 }
            .contains { value in
                let lowered = value.lowercased()
                if lowered.contains("猜拳") || lowered.contains("石头剪刀布") || lowered.contains("骰子") {
                    return true
                }
                let normalized = lowered.unicodeScalars
                    .filter { CharacterSet.alphanumerics.contains($0) }
                    .map(String.init)
                    .joined()
                return allowedASCIIIdentifiers.contains(normalized)
            }
    }
}

/// Yomi 游戏网关临时凭证。该对象不持久化，仅用于拼接本次 Web 游戏地址。
struct PartyGameTokenCode: Equatable {
    let userId: String
    let code: String
    let merchant: String?
    let platform: String?

    static func decode(from data: Data) -> PartyGameTokenCode? {
        guard let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userId = stringValue(values["userId"]),
              let code = stringValue(values["code"]),
              !userId.isEmpty, !code.isEmpty else {
            return nil
        }
        return PartyGameTokenCode(
            userId: userId,
            code: code,
            merchant: stringValue(values["merchant"]),
            platform: stringValue(values["platform"])
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber {
            let type = String(cString: value.objCType)
            if type != "c" && type != "B" { return value.stringValue }
        }
        return nil
    }
}

/// Party 顶部活动资源。后端 `id` 可能是 String 或 Int，因此保留兼容解码。
struct PartyCornerBanner: Codable, Equatable {
    let id: String?
    let picUrl: String?
    let directUrl: String?

    var isDisplayable: Bool {
        picUrl?.isEmpty == false && directUrl?.isEmpty == false
    }

    enum CodingKeys: String, CodingKey { case id, picUrl, directUrl }

    init(id: String? = nil, picUrl: String? = nil, directUrl: String? = nil) {
        self.id = id
        self.picUrl = picUrl
        self.directUrl = directUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(String.self, forKey: .id) {
            id = value
        } else if let value = try? container.decode(Int64.self, forKey: .id) {
            id = String(value)
        } else {
            id = nil
        }
        picUrl = try? container.decode(String.self, forKey: .picUrl)
        directUrl = try? container.decode(String.self, forKey: .directUrl)
    }
}
