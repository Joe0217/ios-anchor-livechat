import Foundation

/// PK 结果类型（对齐 H5 `pkHistoryPopup.vue` L64-72 `resultTypeMap`）。
enum PKRecordResult: Int, Codable {
    case win  = 1
    case loss = 2
    case draw = 3
}

/// PK 历史记录单条（对齐 H5 pkHistoryPopup record 字段 + `/api/pk/getPkRecordList` 响应）。
///
/// H5 结构（反推自 pkHistoryPopup.vue template 使用点）：
/// - `id` / `startTime`（时间戳 ms）/ `resultType`（1胜/2败/3平）
/// - 我方：`avatar` / `nickname` / `pkCounter`（分数）
/// - 对方：`oppositeAnchorId` / `oppositeAvatar` / `oppositeNickname` / `oppositePkCounter`
///
/// **anchorId 字段双兼容**（参 [ios-decode-userid-compat] rule）：`oppositeAnchorId` String/Int 双兼容
struct PKRecordItem: Identifiable, Equatable {
    let id: String
    let startTime: Int64
    let resultType: PKRecordResult
    let avatar: String?
    let nickname: String?
    let pkCounter: Int
    let oppositeAnchorId: String
    let oppositeAvatar: String?
    let oppositeNickname: String?
    let oppositePkCounter: Int
}

extension PKRecordItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, pkId
        case startTime, createTime
        case resultType, result
        case avatar, icon
        case nickname, nickName
        case pkCounter
        case oppositeAnchorId, oppositeUserId
        case oppositeAvatar, oppositeIcon
        case oppositeNickname, oppositeNickName
        case oppositePkCounter
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // id 字段（优先 id / fallback pkId）；String/Int 双兼容
        var idStr: String?
        for key in [CodingKeys.id, .pkId] {
            if let s = try? c.decode(String.self, forKey: key), !s.isEmpty { idStr = s; break }
            if let n = try? c.decode(Int64.self, forKey: key) { idStr = String(n); break }
        }
        self.id = idStr ?? UUID().uuidString

        // startTime（ms 时间戳）；优先 startTime / fallback createTime
        self.startTime = (try? c.decode(Int64.self, forKey: .startTime))
            ?? (try? c.decode(Int64.self, forKey: .createTime))
            ?? 0

        // resultType（Int 1/2/3）；优先 resultType / fallback result
        let resultRaw = (try? c.decode(Int.self, forKey: .resultType))
            ?? (try? c.decode(Int.self, forKey: .result))
            ?? 3
        self.resultType = PKRecordResult(rawValue: resultRaw) ?? .draw

        self.avatar = (try? c.decode(String.self, forKey: .avatar))
            ?? (try? c.decode(String.self, forKey: .icon))
        self.nickname = (try? c.decode(String.self, forKey: .nickname))
            ?? (try? c.decode(String.self, forKey: .nickName))
        self.pkCounter = (try? c.decode(Int.self, forKey: .pkCounter)) ?? 0

        // oppositeAnchorId String/Int 双兼容（[ios-decode-userid-compat]）
        var oppIdStr: String = ""
        for key in [CodingKeys.oppositeAnchorId, .oppositeUserId] {
            if let s = try? c.decode(String.self, forKey: key), !s.isEmpty { oppIdStr = s; break }
            if let n = try? c.decode(Int64.self, forKey: key) { oppIdStr = String(n); break }
        }
        self.oppositeAnchorId = oppIdStr

        self.oppositeAvatar = (try? c.decode(String.self, forKey: .oppositeAvatar))
            ?? (try? c.decode(String.self, forKey: .oppositeIcon))
        self.oppositeNickname = (try? c.decode(String.self, forKey: .oppositeNickname))
            ?? (try? c.decode(String.self, forKey: .oppositeNickName))
        self.oppositePkCounter = (try? c.decode(Int.self, forKey: .oppositePkCounter)) ?? 0
    }
}

/// PK 历史分页响应（对齐 H5 useServerPagination + `records`/`validWinCount`/`totalPkCount` 字段）
struct PKRecordPage: Decodable {
    let records: [PKRecordItem]
    let validWinCount: Int
    let totalPkCount: Int
    let hasMore: Bool

    /// 后端 `result:null` 或空 records 兜底（对齐 H5 `res || []`）
    static let emptyNoMore = PKRecordPage(records: [],
                                          validWinCount: 0,
                                          totalPkCount: 0,
                                          hasMore: false)

    /// memberwise init for static factory only（Decodable 走 init(from:)）
    private init(records: [PKRecordItem], validWinCount: Int, totalPkCount: Int, hasMore: Bool) {
        self.records = records
        self.validWinCount = validWinCount
        self.totalPkCount = totalPkCount
        self.hasMore = hasMore
    }

    private enum CodingKeys: String, CodingKey {
        case records, list, data
        case validWinCount
        case totalPkCount
        case hasMore
        case totalCount, total
        case currentPage
        case pageSize
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.records = (try? c.decode([PKRecordItem].self, forKey: .records))
            ?? (try? c.decode([PKRecordItem].self, forKey: .list))
            ?? (try? c.decode([PKRecordItem].self, forKey: .data))
            ?? []
        self.validWinCount = (try? c.decode(Int.self, forKey: .validWinCount)) ?? 0
        self.totalPkCount = (try? c.decode(Int.self, forKey: .totalPkCount)) ?? 0
        // hasMore 优先服务端字段；缺失时用 `currentPage * pageSize < totalCount` 推
        if let flag = try? c.decode(Bool.self, forKey: .hasMore) {
            self.hasMore = flag
        } else if let total = (try? c.decode(Int.self, forKey: .totalCount))
            ?? (try? c.decode(Int.self, forKey: .total)),
                  let page = try? c.decode(Int.self, forKey: .currentPage),
                  let size = try? c.decode(Int.self, forKey: .pageSize) {
            self.hasMore = page * size < total
        } else {
            // 兜底：records 满页认为有下一页（PageSize 由调用方保证）
            self.hasMore = !records.isEmpty
        }
    }
}
