import Foundation

/// 派对房 Room 模板（`room/getRoomTempList` / `room/getCreateRoomTempList`）。
///
/// 该 model **同时被创房 flow 与 Room Mode 切换 flow 消费**：
/// - **Create flow**（v6 已上线）—— 房主拉模板选布局，字段 `coverImage / seatCount / videoSeatCount /
///   voiceSeatCount / createRoomLevel / modeType` 已在 UI 层引用
/// - **Room Mode flow**（v2 spec §1）—— 房主切模式，同一 API 契约，同字段
///
/// **iOS 命名沿用 create flow 老字段（`coverImage`/`seatCount`/`videoSeatCount`/`voiceSeatCount`）**；
/// 后端真实字段名通过 CodingKeys alias 双向兜底（2026-07-10 真机 log 校准：真机字段名
/// `roomTempId / imgUrl / voiceNum / videoNum / totalSeatNum`，见
/// [agent-recon-field-names-unverified](../.claude/rules/agent-recon-field-names-unverified.md) rule）。
struct PartyRoomTemplate: Decodable, Equatable, Identifiable {
    let id: Int
    let name: String?
    /// 安卓字段名 `modeType`；H5 用户端字段名 `type`（1=Voice / 2=Live+Voice）
    let modeType: Int?
    /// 总麦位数（真机字段 `totalSeatNum`）
    let seatCount: Int?
    /// 视频位数（含接待位，真机字段 `videoNum`）
    let videoSeatCount: Int?
    /// 语聊位数（真机字段 `voiceNum`）
    let voiceSeatCount: Int?
    /// 模板封面图 URL（真机字段 `imgUrl`，iOS 沿用旧命名 `coverImage`）
    let coverImage: String?
    /// 创房者需要达到的最低段位；`userLevel >= createRoomLevel` 才解锁。nil 视为无门槛。
    let createRoomLevel: Int?

    enum CodingKeys: String, CodingKey {
        // iOS 命名
        case id, name, modeType, seatCount, videoSeatCount, voiceSeatCount
        case coverImage
        case createRoomLevel
        // 后端真实字段名（2026-07-10 真机 log 校准）
        case roomTempId        // → id
        case type              // → modeType
        case totalSeatNum      // → seatCount
        case videoNum          // → videoSeatCount
        case voiceNum          // → voiceSeatCount
        case imgUrl            // → coverImage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // id: 后端真名 `roomTempId` 优先，fallback `id`
        if let v = try? c.decode(Int.self, forKey: .roomTempId) {
            id = v
        } else {
            id = try c.decode(Int.self, forKey: .id)
        }
        name = try? c.decode(String.self, forKey: .name)
        modeType = (try? c.decode(Int.self, forKey: .modeType))
                ?? (try? c.decode(Int.self, forKey: .type))
        seatCount = (try? c.decode(Int.self, forKey: .totalSeatNum))
                 ?? (try? c.decode(Int.self, forKey: .seatCount))
        videoSeatCount = (try? c.decode(Int.self, forKey: .videoNum))
                      ?? (try? c.decode(Int.self, forKey: .videoSeatCount))
        voiceSeatCount = (try? c.decode(Int.self, forKey: .voiceNum))
                      ?? (try? c.decode(Int.self, forKey: .voiceSeatCount))
        coverImage = (try? c.decode(String.self, forKey: .imgUrl))
                  ?? (try? c.decode(String.self, forKey: .coverImage))
        createRoomLevel = try? c.decode(Int.self, forKey: .createRoomLevel)
    }

    /// 测试 / Preview memberwise 构造
    init(id: Int, name: String? = nil, modeType: Int? = nil, seatCount: Int? = nil,
         videoSeatCount: Int? = nil, voiceSeatCount: Int? = nil, coverImage: String? = nil,
         createRoomLevel: Int? = nil) {
        self.id = id
        self.name = name
        self.modeType = modeType
        self.seatCount = seatCount
        self.videoSeatCount = videoSeatCount
        self.voiceSeatCount = voiceSeatCount
        self.coverImage = coverImage
        self.createRoomLevel = createRoomLevel
    }
}

/// Room Mode Tab 分类；rawValue 对齐 `getRoomTempList { type }` API 请求参数（spec §1）。
enum PartyRoomModeType: Int, CaseIterable, Identifiable {
    case liveAndVoice = 2
    case voiceOnly = 1

    var id: Int { rawValue }

    var tabTitle: String {
        switch self {
        case .liveAndVoice: return L10n.Party.roomModeLiveAndVoiceTab
        case .voiceOnly:    return L10n.Party.roomModeVoiceOnlyTab
        }
    }
}

/// Room Mode 模板列表拉取状态机（spec §1 UI 态）。
///
/// `partialLoaded` 承载两 tab 并发 `Promise.allSettled` 语义下单 tab 失败、另一 tab 成功的场景 ——
/// 观众端 tab 切换 UX 要求"能显示的先显示"，不因单 tab 失败整体走 error。
enum PartyRoomModeTemplatesState: Equatable {
    case idle
    case loading
    case loaded(voice: [PartyRoomTemplate], live: [PartyRoomTemplate])
    case partialLoaded(voice: [PartyRoomTemplate]?, live: [PartyRoomTemplate]?)
    case error(String)
}
