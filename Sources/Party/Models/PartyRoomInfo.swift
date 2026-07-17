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

    /// 衍生：观众在线人数（用 `onlineUserList.count`；list 接口无独立人数字段）
    var onlineCount: Int { onlineUserList?.count ?? 0 }

    /// 衍生：私 call 是否开启（房主视角）。`partyPrivateCallOpen == 1`。
    /// 用于 CallStore.handleIncomingVideoCall 派对分支前置 guard（对齐 LiveStore.privateCallOpen · P1-9）
    var isPartyPrivateCallEnabled: Bool { partyPrivateCallOpen == 1 }

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
        roomName: String? = nil,
        roomAvatar: String? = nil,
        greetingMessage: String? = nil,
        roomLanguage: String? = nil,
        roomTempId: String? = nil,
        lockFlag: Int? = nil,
        needPassword: Bool? = nil,
        partyPrivateCallOpen: Int? = nil,
        partyCallGiftId: String? = nil,
        partyCallGiftImg: String? = nil,
        partyCallGiftPrice: Int? = nil,
        onSeatApplySwitch: Bool? = nil
    ) -> PartyRoomInfo {
        PartyRoomInfo(
            id: id,
            ownerId: ownerId,
            roomRoleType: roomRoleType,
            isPlatformAdmin: isPlatformAdmin,
            roomName: roomName ?? self.roomName,
            roomAvatar: roomAvatar ?? self.roomAvatar,
            greetingMessage: greetingMessage ?? self.greetingMessage,
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
            pkStatus: pkStatus,
            pkId: pkId,
            isFollowOwner: isFollowOwner,
            contributionCostNum: contributionCostNum,
            honorDailyTotal: honorDailyTotal,
            audienceNum: audienceNum,
            roomSeatList: roomSeatList,
            bgImgUrl: bgImgUrl,
            bigImgUrl: bigImgUrl,
            partyPrivateCallOpen: partyPrivateCallOpen ?? self.partyPrivateCallOpen,
            partyCallGiftId: partyCallGiftId ?? self.partyCallGiftId,
            partyCallGiftImg: partyCallGiftImg ?? self.partyCallGiftImg,
            partyCallGiftPrice: partyCallGiftPrice ?? self.partyCallGiftPrice,
            onSeatApplySwitch: onSeatApplySwitch ?? self.onSeatApplySwitch
        )
    }
}
