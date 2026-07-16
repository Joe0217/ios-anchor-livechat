import Foundation

/// F 里程碑：派对房私 call 状态通知（NIM 聊天室 attachType=1029）
///
/// **1029 双重定义防御**（spec §4.2 P0-4）：安卓 `NIMMsgAttachType.java` 中 1029 同时定义了
/// `PARTY_PRIVATE_CALL_NOTIFY` 与 `PARTY_ROOM_GIFT_DOUBLED`。iOS 通过 `status` enum 严格
/// 校验区分：payload 缺 `status` 或 `status` 值不属 `{calling, ended}` → decode throw → Router drop。
///
/// **通道**：NIM 聊天室广播（房内所有客户端可见），非 P2P。
///
/// **⚠️ 字段真实性待 Step 3 首次真机 log 校准**（rule: im-payload-real-log-over-code-assumption）：
/// 预估字段基于安卓源码梳理 §2.3；真机收到后按 `dataKeys=` log 补 CodingKeys 兼容。
struct PartyPrivateCallNotify: Decodable, Equatable {
    /// 通话生命周期状态。严格 enum，缺失/非法 → decoder throw → Router drop（区分 GIFT_DOUBLED 语义）。
    enum Status: String, Decodable, Equatable {
        case calling
        case ended
    }

    /// 主播 userId（被叫方）· String/Int 双兼容 decode
    let userId: String
    let nickname: String?
    let seatIndex: Int?
    /// 生命周期。硬要求：payload 必须含此字段且值 ∈ {calling, ended}
    let status: Status
    /// 呼叫方 userId · String/Int 双兼容
    let callerUserId: String?
    let callerNickname: String?
    let callerSeatIndex: Int?
    /// 房间维度私 call 开关状态：0=关 / 1=开
    let partyCallOpen: Int?

    enum CodingKeys: String, CodingKey {
        case userId, nickname, seatIndex, status
        case callerUserId, callerNickname, callerSeatIndex
        case partyCallOpen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // status 硬要求（1029 双重定义防御 · P0-4）
        // 若 GIFT_DOUBLED 语义下没有 status 字段 → throw dataCorrupted → Router drop 无副作用
        self.status = try c.decode(Status.self, forKey: .status)

        // userId · String/Int 双兼容（rule: ios-decode-userid-compat）
        if let s = try? c.decode(String.self, forKey: .userId), !s.isEmpty {
            self.userId = s
        } else if let n = try? c.decode(Int64.self, forKey: .userId) {
            self.userId = String(n)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .userId, in: c,
                debugDescription: "userId neither String nor Int64"
            )
        }

        self.nickname = try? c.decode(String.self, forKey: .nickname)
        self.seatIndex = try? c.decode(Int.self, forKey: .seatIndex)

        // callerUserId · String/Int 双兼容 optional
        if let s = try? c.decode(String.self, forKey: .callerUserId), !s.isEmpty {
            self.callerUserId = s
        } else if let n = try? c.decode(Int64.self, forKey: .callerUserId) {
            self.callerUserId = String(n)
        } else {
            self.callerUserId = nil
        }

        self.callerNickname = try? c.decode(String.self, forKey: .callerNickname)
        self.callerSeatIndex = try? c.decode(Int.self, forKey: .callerSeatIndex)
        self.partyCallOpen = try? c.decode(Int.self, forKey: .partyCallOpen)
    }
}
