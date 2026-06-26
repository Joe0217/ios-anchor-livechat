import Foundation

/// 派对房 NIM 自定义消息 `attachType` 枚举（spec §1.4.2 + §1.0.2 第 9 条强制 enum 转换原则）。
///
/// 真值来源：用户提供的"安卓主播端 IM 通知常量配置整理"§L 派对房运行时事件 + §M 房主视频位邀请。
///
/// 严格禁止：项目内任何 attachType 判定**必须**经 `PartyAttachType(rawValue:)` 转换，
/// 禁止裸 Int 比较（参照安卓 `PartyRoomVM.kt:368` 裸 `1100..1112` 反例）。
///
/// E MVP 范围：6 类核心 + 9 类 INVITE_VIDEO_SEAT 响应。F 期再扩 1004 座驾 / 1014 鉴黄 /
/// 1017 切模板 / 1018-1027 排麦/任务/管理员 / 1049 房间通告 / 1050-1052 LuckyNumber /
/// 1100-1112 PartyBattle。
enum PartyAttachType: Int {
    // MARK: - 核心房态信令（MVP 必接 6 类）

    /// 1001 麦位变化通知（gzip + Base64 压缩 payload）
    case seatUpdate = 1001
    /// 1003 被踢出派对房（双字段守护 userId+roomId 才退房，spec §1.4.4）
    case kickedOut = 1003
    /// 1008 麦克风/摄像头状态变化（视频位的 onMediaChange 入口，v2 新增）
    case updateMedia = 1008
    /// 1012 更新麦位列表（触发全量 `seat/list` 重拉）
    case seatUpdateList = 1012
    /// 1015 禁麦 / 解禁麦
    case prohibitMic = 1015
    /// 2049 礼物压缩版（gzip + Base64；与 1007 双发去重——iOS 只识别 2049）
    case giftCompressed = 2049

    // MARK: - 视频位邀请响应（MVP 9 类；主动发起 inviteOnSeat 推 F）

    /// 1040 邀请上视频位（被邀请用户收到 → PartyStore.pendingVideoSeatInvite 弹窗）
    case inviteVideoSeat = 1040
    case inviteVideoSeatAccept = 1041
    case inviteVideoSeatReject = 1042
    case inviteVideoSeatTimeout = 1043
    case inviteVideoSeatLeave = 1044
    case inviteVideoSeatOccupied = 1045
    case inviteVideoSeatAlreadyOn = 1046
    case inviteVideoSeatBroadcast = 1047
    case inviteVideoSeatJoinFailed = 1048

    // MARK: - 转换辅助

    /// 与 init(rawValue:) 等价；语义上更明确"必须经此转换"，禁止裸 Int 比较。
    static func from(rawValue: Int) -> PartyAttachType? {
        PartyAttachType(rawValue: rawValue)
    }

    /// 映射到公屏渲染 `PartyMsgType`。多数 attachType 是房态信令不上公屏 → nil。
    func toMsgType() -> PartyMsgType? {
        switch self {
        case .giftCompressed:
            return .gift
        default:
            return nil
        }
    }
}

/// E 期不识别但日志中可能出现的已知 attachType（用于"unrecognized" 时降噪辅助）。
/// 值冲突项（45 / 1029）+ F/H/I/J 期范围内的 attachType 均在此列表中。
enum PartyKnownButUnhandledAttachType {
    /// E 不识别但日志可见的派对房相关 attachType（不含会话气泡等无关项）。
    static let codes: Set<Int> = [
        // 值冲突（spec §1.0.2）
        45, 1029,
        // 派对房 F/H/I/J 期范围
        -10, -11,           // EMOJI / EMOJI_PLAY
        1004, 1009, 1010, 1011, 1013, 1014, 1017, 1018, 1019, 1021,
        1022, 1023, 1024, 1025, 1026, 1049,
        1050, 1051, 1052,   // LuckyNumber
        1100, 1101, 1102, 1103, 1104, 1105, 1106,
        1107, 1108, 1109, 1110, 1111, 1112,  // PartyBattle
        // 老版送礼（iOS 一刀切忽略）
        1007,
    ]
}
