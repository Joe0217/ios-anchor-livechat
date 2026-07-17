import Foundation

/// 派对房表情面板数据模型（F 里程碑 · 对齐 H5 蓝本 `party-expression-popup.vue` +
/// `livechat-h5/src/api/pay/index.ts:4-20` `PartyEmojiClassification` / `PartyEmojiItem`）。
///
/// 面板结构 = 分类列表（`classType/coverImage/emojisList`） × 每分类内 emoji 数组
/// （`id/minImage/gifImage/playType/resultImages`）。
///
/// **静态 vs 玩法区分**（对齐 H5 `constant/party.ts:30-37` `isPartyPlayEmoji`）：
/// - `playType` 空/nil/"normal" → 静态表情 → IM attachType `-10` (`.emojiStatic`)
/// - `playType` 非空非 "normal" → 玩法表情 → IM attachType `-11` (`.emojiPlay`)
///
/// **id 字段 String/Int 双兼容 decode**（[ios-decode-userid-compat] 铁律：H5 type.ts 字段类型不可信 ·
/// 真机可能返 String 或 Number）。
struct PartyEmojiClassification: Decodable, Identifiable, Equatable {
    /// 分类 code（如 "normal" / "party-play" / 自定义业务码）—— 作 Identifiable id 用
    let classType: String
    /// 分类底部 tab 圆形图标 URL（H5 `party-expression-popup.vue` L189 tab.coverImage）
    let coverImage: String?
    /// 分类下所有表情
    let emojisList: [PartyEmojiItem]

    var id: String { classType }
}

/// 单个表情项。字段全部对齐 H5 `PartyEmojiItem`（`livechat-h5/src/api/pay/index.ts:4-13`）。
struct PartyEmojiItem: Decodable, Identifiable, Equatable {
    /// 表情 id —— **必须 String/Int 双兼容 decode**（真机字段类型不定）。SwiftUI ForEach 用
    let id: String
    /// 冗余分类归属（可用可不用；面板不消费）
    let classType: String?
    /// panel grid 展示缩略图（4×2 内 56×56 那个 URL）
    let minImage: String?
    /// 静态表情的动图 URL（`.emojiStatic` payload.playUrl 取此字段）
    let gifImage: String?
    /// 玩法类型：空/nil/"normal" → 静态；其他非空 → 玩法（H5 `isPartyPlayEmoji`）
    let playType: String?
    /// 玩法表情的随机结果池（客户端发送时随机抽一个 → payload.playUrl = picked.image）
    let resultImages: [PartyEmojiResultImage]?

    /// H5 判定语义 `isPartyPlayEmoji(playType)` iOS 侧派生：非空 && != "normal"
    var isPlayEmoji: Bool {
        guard let p = playType, !p.isEmpty else { return false }
        return p != "normal"
    }

    private enum CodingKeys: String, CodingKey {
        case id, classType, minImage, gifImage, playType, resultImages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // id String/Int 双兼容（对齐 [ios-decode-userid-compat] rule）
        if let s = try? c.decode(String.self, forKey: .id), !s.isEmpty {
            self.id = s
        } else if let i = try? c.decode(Int64.self, forKey: .id) {
            self.id = String(i)
        } else if let d = try? c.decode(Double.self, forKey: .id) {
            self.id = String(Int64(d))
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: c,
                debugDescription: "PartyEmojiItem.id neither String nor Number"
            )
        }
        self.classType = try? c.decode(String.self, forKey: .classType)
        self.minImage = try? c.decode(String.self, forKey: .minImage)
        self.gifImage = try? c.decode(String.self, forKey: .gifImage)
        self.playType = try? c.decode(String.self, forKey: .playType)
        self.resultImages = try? c.decode([PartyEmojiResultImage].self, forKey: .resultImages)
    }
}

/// 玩法表情结果池单项（H5 `PartyEmojiItem.resultImages: [{key, image}]`）。
///
/// 发送时客户端从 `resultImages` 随机抽一个 → payload 传 `playUrl: picked.image` + `resultKey: picked.key`；
/// 接收端不重抽（对齐 H5 `usePartyHooks.js:1810-1820` 明示"客户端发送时随机 · 收端直接播 playUrl"）。
struct PartyEmojiResultImage: Decodable, Equatable {
    /// 结果标识（骰子点数 / 抽奖结果值等业务语义 key）
    let key: String
    /// 该结果对应的 SVGA URL
    let image: String
}

/// 麦位内 SVGA 播放队列的最小 payload（IM 收到 -10/-11 → 派生此结构入队）。
///
/// 与 `PartyEmojiItem` 分离：
/// - `PartyEmojiItem` 是面板 list 数据（Decoder 从 HTTP list decode）
/// - `EmojiPayload` 是 IM 消息载荷（从 remoteExt.data 解出 · 只保留播放必要字段）
///
/// SwiftUI ForEach 用 `uuid`（同一 emojiId 多次入队时 emojiId 会冲突）。
struct PartyEmojiPayload: Identifiable, Equatable {
    /// SwiftUI ForEach 稳定 id（每次入队一个新 UUID）
    let uuid: UUID
    /// 表情 id（对齐 H5 payload `data.id`）
    let emojiId: String
    /// 播放 URL：静态取 `gifImage` · 玩法取 `resultImages[picked].image`（对齐 H5 `data.playUrl`）
    let playUrl: String
    /// 玩法类型（可 nil；静态表情为 nil）
    let playType: String?
    /// 玩法抽中结果 key（可 nil；静态表情为 nil）
    let resultKey: String?
    /// 发送时间戳 ms（对齐 H5 `data.timestamp`；仅玩法附带）
    let timestamp: Int64?
    /// 发送者 userId（用于 self-echo skip 判定；本地 enqueue 也带此字段方便 debug log）
    let sendUserId: String

    var id: UUID { uuid }

    /// 从 IM 收到的 payload dict 派生（router.handle 内 unwrapDataField 后调用）。
    /// 字段名严格对齐 H5 `usePartyHooks.js:1756-1833` payload 结构；无 alias。
    static func from(payload: [String: Any]) -> PartyEmojiPayload? {
        // playUrl / emojiId / sendUserId 是必要字段；缺任一直接 drop（防 SVGA 加载 nil URL 崩）
        let emojiId = PartyValueNormalizer.stringify(payload["id"]) ?? ""
        let playUrl = (payload["playUrl"] as? String) ?? ""
        let sendUserId = PartyValueNormalizer.stringify(payload["sendUserId"]) ?? ""
        guard !emojiId.isEmpty, !playUrl.isEmpty, !sendUserId.isEmpty else {
            return nil
        }
        let playType = payload["playType"] as? String
        let resultKey = payload["resultKey"] as? String
        let timestamp = PartyValueNormalizer.intify(payload["timestamp"]).map { Int64($0) }
        return PartyEmojiPayload(
            uuid: UUID(),
            emojiId: emojiId,
            playUrl: playUrl,
            playType: (playType?.isEmpty == false) ? playType : nil,
            resultKey: (resultKey?.isEmpty == false) ? resultKey : nil,
            timestamp: timestamp,
            sendUserId: sendUserId
        )
    }
}

/// 面板 list 加载状态机（对齐 [async-state-fallback] rule · 有 idle/loading/loaded/error 4 态；
/// loaded 后不重拉 · error 态显 retry 按钮）。
enum PartyEmojiListState: Equatable {
    case idle
    case loading
    case loaded([PartyEmojiClassification])
    case error(String)
}
