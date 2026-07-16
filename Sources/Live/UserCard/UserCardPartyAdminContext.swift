import Foundation

/// UserCardPopup 派对房 admin 操作上下文(对齐 H5 `party-user-card.vue` showAdminActions 逻辑)。
///
/// **由 PartyRoomView 注入** —— tap 麦位/在线用户头像时,把当前 PartyStore 派生的权限数据 + action closures 打包传给 sheet。
/// 非派对房场景(LiveRoom/ChatDetail)传 `nil` 隐藏整个 admin action row。
///
/// **权限矩阵**(对齐 H5 `showAdminActions` L114-137):
/// - 我方(selfRole)必须是 owner 或 admin
/// - 目标非我自己(caller 判断,不进入这里)
/// - 目标非房主(隐藏)
/// - admin 只能操作 audience(观众/普通用户);owner 可操作 admin+audience
///
/// **单项按钮显示规则**:
/// - `Mute/Unmute`:目标在**语音麦位**上(seatType=voice)+ 目标非房主
/// - `Take/Leave`(抱下麦,不做抱上):目标在麦上 + 目标非房主
/// - `Set/Remove Admin`:**仅 owner** 可看;目标可以是 audience(设为 admin) 或 admin(移除)
/// - `Kick out`:目标是 audience(普通用户);owner/admin 均可点
struct PartyAdminContext {
    /// 我方在派对房内的角色(仅 owner/admin 才会有 admin row 显示)
    let selfRole: PartyRoomRoleType
    /// 目标用户所在麦位(nil = 目标不在麦位;抱下麦/Mute 按钮此时隐藏)
    let targetSeat: PartyRoomSeat?
    /// 目标用户房内角色(nil = 目标不在房间;仅用于 kick 分支)
    let targetRoleType: PartyRoomRoleType?
    /// 派对房 id(埋点用,现阶段仅传递)
    let roomId: String
    /// 有限时长踢房时长(小时,H5 partyBaseConfig.kickOutInterval / 3600)。<=0 时 UI 按钮文案降级为 "Limited"
    let kickOutHours: Int

    // MARK: - Actions(由 caller 提供,内部通常调 PartyStore.requestXxx)

    /// 抱下麦(仅目标在麦上时可触发;seatIndex 由 targetSeat.seatIndex 派生)
    let onKickFromMic: (_ targetUserId: String, _ seatIndex: Int) -> Void
    /// 切换禁麦(mute=true 禁麦, false 解禁)
    let onToggleMute: (_ seatIndex: Int, _ mute: Bool) -> Void
    /// 设置/移除房管(仅 owner 可触发)
    let onSetAdmin: (_ targetUserId: String, _ add: Bool) -> Void
    /// 踢出房间(seatIndex -1 = 目标不在麦上)
    let onKickOutRoom: (_ seatIndex: Int, _ targetUserId: String, _ banType: Int) -> Void

    // MARK: - 派生态(UI 层直接消费)

    /// 我方是否有 admin 权限
    var hasAdminPermission: Bool {
        selfRole == .owner || selfRole == .admin
    }

    /// 是否显示整条 admin action row(H5 showAdminActions 精简版;caller 判 isSelf 后再传 context)
    var canShowAdminActions: Bool {
        guard hasAdminPermission else { return false }
        // 目标是房主 → 隐藏(不可操作)
        if targetRoleType == .owner { return false }
        // 房管只能操作普通用户(audience)
        if selfRole == .admin && targetRoleType != .audience { return false }
        return true
    }

    /// 是否显示 Mute/Unmute(仅目标在语音麦位)
    var canShowMuteToggle: Bool {
        guard let seat = targetSeat, let type = seat.seatType else { return false }
        return type == PartyRoomSeatType.voice.rawValue
    }

    /// 是否显示"抱下麦"(仅目标在麦位)
    var canShowKickFromMic: Bool {
        guard let seat = targetSeat, seat.seatIndex != nil else { return false }
        return true
    }

    /// 是否显示 Set/Remove Admin(**仅 owner** 可见)
    var canShowSetAdmin: Bool {
        selfRole == .owner
    }

    /// 是否显示 Kick out(目标为 audience)
    var canShowKickOut: Bool {
        targetRoleType == .audience
    }

    /// 目标当前是否已被禁麦(seatMicrophoneEnabled == 0)
    var isTargetMuted: Bool {
        guard let seat = targetSeat, let enabled = seat.seatMicrophoneEnabled else { return false }
        return enabled == 0
    }

    /// 目标当前是否已是房管
    var isTargetAdmin: Bool {
        targetRoleType == .admin
    }
}
