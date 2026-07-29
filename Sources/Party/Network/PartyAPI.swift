import Foundation

/// 派对房 HTTP 端点封装（MVP 必接 10 个，spec §1.4.1）。
///
/// 路径前缀统一 `/sapi/weidou/v1/client/party`（H5 接口参考 §1 + `src/sapi/marketing/index.ts` 风格）。
/// 全部走 `PartyAPIClient`：vvi 域名 + sapi 鉴权 + envelope `code=='200'` + AES Hex 解密。
///
/// 错误：底层 `PartyAPIError` 抛上来，调用方按需 `PartyRoomErrorMapper.map(_)` 映射成 `PartyRoomError`。
/// 注意业务参数：
/// - 所有 seat/* 接口必带 `yxRoomId + roomTempId`（接口参考 §6 明示"易漏"）
/// - `updateMedia.enable` 用 Int 1/0 而非 Bool（兼容后端常见编码；M5 实测后端反馈再调）
enum PartyAPI {
    private static let pathPrefix = "/sapi/weidou/v1/client/party"
    private static let decoder = JSONDecoder()

    /// 房间/座位类接口业务码 opt-out：PartyRoomErrorMapper 已识别、业务侧独立处理（自动重拉对账 /
    /// 密码 sheet 内联 / 封禁弹窗等），不弹全局 banner 避免与业务 UI 双弹。
    /// caller: enterRoom / onSeat / downSeat / exchangeSeat / holdSeat / lockSeat / setMCSeat 等。
    private static let roomBusinessSuppress: Set<String> = [
        "ROOM_SEAT_IS_OCCUPIED",   // → PartyStore.seatOccupied 自动 reloadSeatList
        "ROOM_SEAT_EMPTY",         // → PartyStore.seatEmpty 自动 reloadSeatList
        "10006",                   // → 密码 sheet 内联（H5 enterRoom 密码错误码）
        "ROOM_PASSWORD_WRONG",     // → 密码 sheet 内联
        "PASSWORD_ERROR",          // 同上
        "USER_BANNED",             // → 独立封禁提示
        "LIVING_BE_BANNED",        // 同上
        "LEVEL_INSUFFICIENT",      // → 独立等级不足提示
    ]

    /// 送礼接口业务码 opt-out：1019 diamond not enough → CommonGiftPanelStore 独立充值弹窗。
    private static let giftBusinessSuppress: Set<String> = ["1019"]

    // MARK: - 私有解码辅助

    /// 兼容三种 sapi 返回 schema：
    /// 1. envelope.result 直接是数组 `[...]`
    /// 2. envelope.result 是分页包装 `{list/records/data/rows/items: [...], ...}`
    /// 3. envelope.result 是 "null" 字面值（视为空数组）
    /// 任一路径解码成功即返回；全部失败时打印 raw JSON 后抛具体 DecodingError 供排查字段类型不符。
    private static func decodeArrayOrEmpty<T: Decodable>(_ data: Data, as: T.Type) throws -> [T] {
        let rawPreview = String(data: data, encoding: .utf8) ?? "<binary>"
        if rawPreview == "null" { return [] }

        // 1. 直接数组
        if let arr = try? decoder.decode([T].self, from: data) { return arr }

        // 2. wrapper key 探测
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["list", "records", "data", "rows", "items"] {
                guard let inner = dict[key] else { continue }
                guard JSONSerialization.isValidJSONObject(inner) else { continue }
                if let innerData = try? JSONSerialization.data(withJSONObject: inner),
                   let arr = try? decoder.decode([T].self, from: innerData) {
                    AppLogger.party.info("[PartyAPI] decoded array via wrapper key '\(key, privacy: .public)'")
                    return arr
                }
            }
        }

        // 3. 全部失败 → 打 raw + 抛真实 DecodingError 让上层看到具体字段错
        // raw 是 AES 解密后的明文业务数据（含 PII / 收益等），Release 包必须脱敏
        AppLogger.party.error("[PartyAPI] decode array failed; raw=\(rawPreview, privacy: .private)")
        return try decoder.decode([T].self, from: data)
    }

    /// 单对象解码：兼容 envelope.result 是 `{... 业务字段 ...}` 直接对象 / `{data: {...}}` 包装。
    private static func decodeObject<T: Decodable>(_ data: Data, as: T.Type) throws -> T {
        // 1. 直接对象
        if let obj = try? decoder.decode(T.self, from: data) { return obj }

        // 2. 单层包装探测
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["data", "result", "info"] {
                guard let inner = dict[key] else { continue }
                guard JSONSerialization.isValidJSONObject(inner) else { continue }
                if let innerData = try? JSONSerialization.data(withJSONObject: inner),
                   let obj = try? decoder.decode(T.self, from: innerData) {
                    AppLogger.party.info("[PartyAPI] decoded object via wrapper key '\(key, privacy: .public)'")
                    return obj
                }
            }
        }

        // 3. 失败 → 打 raw + 抛真实 DecodingError
        // raw 是 AES 解密后的明文业务数据（含 PII / 收益等），Release 包必须脱敏
        let rawPreview = String(data: data, encoding: .utf8) ?? "<binary>"
        AppLogger.party.error("[PartyAPI] decode object failed; raw=\(rawPreview, privacy: .private)")
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - 半屏游戏

    /// 主播端 Party 半屏游戏资源。必须使用 anchor 游戏池，不能复用用户端
    /// `/half/geme/v2/list`，否则服务端会按用户角色返回错误的游戏集合。
    static func anchorPartyBannerGames() async throws -> [PartyBannerGame] {
        let data = try await APIClient.shared.post("/api/half/geme/anchor/list", body: [:])
        #if DEBUG
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        AppLogger.party.debug("[PartyGame] anchor/list raw=\(raw, privacy: .private)")
        #endif
        let games = try PartyBannerGame.decodeAnchorBannerGames(from: data)
        AppLogger.party.info("[PartyGame] anchor/list decoded count=\(games.count, privacy: .public)")
        return games
    }

    /// Yomi 游戏进入码。字段由游戏服务控制，首次真机调用会留下脱敏原始 payload 供校验。
    static func gameTokenCode() async throws -> PartyGameTokenCode? {
        let data = try await APIClient.shared.post("/api/half/geme/getTokenCode", body: [:])
        #if DEBUG
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        AppLogger.party.debug("[PartyGame] getTokenCode raw=\(raw, privacy: .private)")
        #endif
        return PartyGameTokenCode.decode(from: data)
    }

    // MARK: - room

    /// 房间模板列表（创建房间前选模板用）。
    ///
    /// **对齐 H5 用户端 `apiGetRoomTempList({type})`**（`livechat-h5/src/api/party/index.ts:36`）：
    /// - `type: 1` = Voice（纯语聊）
    /// - `type: 2` = Live+Voice（视频+语聊混合）
    /// - `type: 0` = MVP 兜底（当调用方未明示 mode 时用）
    static func roomTempList(type: Int = 0) async throws -> [PartyRoomTemplate] {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getRoomTempList",
            body: ["type": type]
        )
        return try decodeArrayOrEmpty(data, as: PartyRoomTemplate.self)
    }

    /// 派对房支持语言列表（创建房间语言 picker 用）。
    ///
    /// **对齐 H5 用户端 `apiGetLanguageList()`**（`livechat-h5/src/api/party/index.ts:33`）：
    /// 无参 POST；response 是 `[{languageName, languageCode}]`。
    static func languageList() async throws -> [PartyLanguage] {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/language/list",
            body: [:]
        )
        return try decodeArrayOrEmpty(data, as: PartyLanguage.self)
    }

    /// 房内一键发送词条。对齐 H5 `apiGetQuickPhrases`：
    /// `audienceType` 为 1 时返回用户词条，2 时返回主播词条。
    static func quickPhrases(audienceType: Int) async throws -> [PartyQuickPhrase] {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getQuickPhrases",
            body: ["audienceType": audienceType]
        )
        return try decodeArrayOrEmpty(data, as: PartyQuickPhrase.self)
    }

    /// 创房权限校验（Party 首页点"创建"时前置 gate）。
    ///
    /// **对齐 H5 `apiGetPartyRoomAuth`** + 安卓 `PartyVM.getCreatePartyRoomConditions`。
    /// POST `/room/getCreateRoomConditions`，无参；response `{canCreateRoom, createRoomLevel, isWithlist}`。
    static func getCreateRoomConditions() async throws -> PartyCreateConditions {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getCreateRoomConditions",
            body: [:]
        )
        return try decodeObject(data, as: PartyCreateConditions.self)
    }

    /// Party 房基础配置。对齐 H5 `apiGetPartyBaseConfig`。
    static func getPartyBaseConfig() async throws -> PartyBaseConfig {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getPartyBaseConfig",
            body: [:]
        )
        return try decodeObject(data, as: PartyBaseConfig.self)
    }

    /// 派对房背景图列表（创房 Background picker 用）。
    ///
    /// **对齐 H5 `apiGetPartyBgImages`** + 安卓 `getRoomBgImages`。
    /// POST `/room/getBgImages`，参数 `{pageSize, offset}`；response `[{id, imgUrl, bigImgUrl, bgImgName, duration}]`。
    static func backgroundList(pageSize: Int = 50, offset: Int = 0) async throws -> [PartyBackground] {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getBgImages",
            body: ["pageSize": pageSize, "offset": offset]
        )
        return try decodeArrayOrEmpty(data, as: PartyBackground.self)
    }

    // MARK: - room settings（设置功能，2026-07-13 v8）

    /// 更新房间信息（房主设置页 save 时调）。
    /// 对齐 H5 `apiPartyUpdateRoom` 与安卓 `updateRoom`。
    /// **仅传变更 diff**（对齐 H5 create.vue:296-302；nil 参数跳过 body key）。
    static func updateRoom(
        roomId: String,
        roomName: String? = nil,
        roomAvatar: String? = nil,
        greetingMessage: String? = nil,
        roomLanguage: String? = nil
    ) async throws {
        var body: [String: Any] = ["roomId": roomId]
        if let v = roomName { body["roomName"] = v }
        if let v = roomAvatar { body["roomAvatar"] = v }
        if let v = greetingMessage { body["greetingMessage"] = v }
        if let v = roomLanguage { body["roomLanguage"] = v }
        _ = try await PartyAPIClient.shared.post("\(pathPrefix)/room/updateRoom", body: body)
    }

    /// 修改房间公告。公告与 `greetingMessage` 是不同字段，成功后服务端以 1049 广播到房间公屏。
    /// 对齐 H5 `apiPartyEditAnnouncement`。
    static func editAnnouncement(roomId: String, announcement: String) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/editAnnouncement",
            body: ["roomId": roomId, "announcement": announcement]
        )
    }

    /// 拉当前房间的背景（编辑态显示 selectedBackground 用）。
    /// 对齐 H5 `apiGetRoomBgImage`（index.ts:260）。
    ///
    /// v16.5 排查：H5 create.vue:216 只消费 `res.id`（拿背景 ID 匹配 backgrounds list），
    /// **不消费 `imgUrl` / `bigImgUrl`** —— 意味着后端 `getRoomBgImage` 可能只返 `{id: X}` 而无 URL 字段，
    /// iOS `PartyBackground` model 声明 imgUrl/bigImgUrl 为 Optional decode 静默变 nil。
    /// **必须**打 raw JSON log 让真机验证后端返值 schema，才能对齐 [agent-recon-field-names-unverified] rule。
    static func getRoomBgImage(roomId: String) async throws -> PartyBackground? {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getRoomBgImage",
            body: ["roomId": roomId]
        )
        // v16.5：raw JSON 排查真机字段名（decode 完成后无论成功失败都能看到后端到底返啥）
        let rawPreview = String(data: data, encoding: .utf8) ?? "<binary>"
        AppLogger.party.info("[PartyAPI] getRoomBgImage raw=\(rawPreview, privacy: .private)")
        let result = try? decodeObject(data, as: PartyBackground.self)
        AppLogger.party.info("[PartyAPI] getRoomBgImage decoded id=\(String(describing: result?.id), privacy: .public) imgUrl=\(result?.imgUrl ?? "nil", privacy: .public) bigImgUrl=\(result?.bigImgUrl ?? "nil", privacy: .public)")
        return result
    }

    /// 设置房间背景（编辑态即时保存，选完 sheet close 就调）。
    /// 对齐 H5 `apiSetPartyBgImage`（index.ts:257）。
    static func setBgImages(roomId: String, bgImgId: Int) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/setBgImages",
            body: ["roomId": roomId, "bgImgId": bgImgId]
        )
    }

    // 房管设置/撤销：见下方 `setAdmin(roomId:userId:operationType:)`（party-user-card 已有，复用）
    // 房管列表：H5 用户端无独立接口；用 `partyOnlineViewers(type: 1)` + 客户端筛 `roomRoleType == 2`

    // MARK: - room rank / viewers（顶栏财富/荣誉/观众入口）

    /// 派对房贡献榜（对齐 H5 `apiGetPartyContributionRank`；顶栏 wealth 数据点击触发）。
    ///
    /// **path**：`/sapi/weidou/v1/client/party/room/rank/getContributionRanks`
    /// **body**：`{roomId, rankType: 'day'|'week'|'month', periodType?: 'CURRENT'|'LAST'}`
    /// **response**：`{rankList: [PartyRankEntry], myRank: {...}, duration: Int(秒)}`
    ///
    static func partyContributionRank(roomId: String,
                                      rankType: String = "day",
                                      periodType: String? = nil) async throws -> PartyRankResponse {
        var body: [String: Any] = ["roomId": roomId, "rankType": rankType]
        if let p = periodType { body["periodType"] = p }
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/rank/getContributionRanks",
            body: body
        )
        return try decodeRankResponse(data)
    }

    /// 派对房荣誉榜（对齐 H5 `apiGetPartyHonorRank`；顶栏 honor 数据点击触发）。
    ///
    /// **path**：`/sapi/weidou/v1/client/party/room/rank/getHonorRanks`
    /// body/response 与贡献榜相同（Honor 无月榜由 UI 层限制）。
    static func partyHonorRank(roomId: String,
                               rankType: String = "day",
                               periodType: String? = nil) async throws -> PartyRankResponse {
        var body: [String: Any] = ["roomId": roomId, "rankType": rankType]
        if let p = periodType { body["periodType"] = p }
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/rank/getHonorRanks",
            body: body
        )
        return try decodeRankResponse(data)
    }

    // MARK: - lobby ranking (Party Rich / Room)

    /// H5 `/party/rank` PartyRich 榜，不带 roomId。
    static func partyRichRank(rankType: String, periodType: String) async throws -> PartyLobbyRankResponse {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/rank/getPartyRichRanks",
            body: ["rankType": rankType, "periodType": periodType]
        )
        return try decodeObject(data, as: PartyLobbyRankResponse.self)
    }

    /// H5 `/party/rank` Room 榜，不带 roomId。
    static func partyLobbyRoomRank(rankType: String, periodType: String) async throws -> PartyLobbyRankResponse {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/rank/getRoomRanks",
            body: ["rankType": rankType, "periodType": periodType]
        )
        return try decodeObject(data, as: PartyLobbyRankResponse.self)
    }

    /// 大厅双卡真实 Top3 头像（H5 `getTop3RanksAvatar`）。
    static func partyLobbyTop3Ranks() async throws -> PartyLobbyTop3Response {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/rank/getTop3RanksAvatar",
            body: [:]
        )
        return try decodeObject(data, as: PartyLobbyTop3Response.self)
    }

    /// Party Tab 首页 banner。H5 `apiGetPartyHomeBannerList` 使用 GET，不能复用首页的通用图片配置接口。
    static func partyHomeBanners() async throws -> [PartyHomeBanner] {
        let data = try await PartyAPIClient.shared.get("\(pathPrefix)/room/homeBanner/list")
        return try decodeArrayOrEmpty(data, as: PartyHomeBanner.self)
    }

    /// Party Rich / Room 周月榜规则图。H5 按活动编号请求 `ruleContent`。
    static func partyLobbyRankRuleContent(belongAct: Int) async throws -> String? {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getRulePageConfigByAct",
            body: ["belongAct": belongAct]
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["ruleContent"] as? String
    }

    /// 派对房在线观众列表（对齐 H5 `apiGetPartyOnlineList`；顶栏观众数点击触发）。
    ///
    /// **path**：`/sapi/weidou/v1/client/party/room/getViewers`
    /// **body**：`{roomId, offset: Any?, pageSize, needTotalCount: Bool}`
    /// **response**：数组或 `{list, offset}`；`offset` 必须透传上一页末项的 `score`。
    static func partyOnlineViewers(
        roomId: String,
        pageSize: Int = 10,
        offset: String? = nil,
        type: Int? = nil
    ) async throws -> [PartyRankEntry] {
        var body: [String: Any] = [
            "roomId": roomId,
            "offset": offset ?? NSNull(),
            "pageSize": pageSize,
            "needTotalCount": true
        ]
        // type=1 触发后端过滤为"房主/房管"候选（H5 party-admin-popup.vue params 传 type:1）
        if let type { body["type"] = type }
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getViewers",
            body: body
        )
        return try decodeArrayOrEmpty(data, as: PartyRankEntry.self)
    }

    /// 游戏任务激励排行榜（安卓 `PartyRoomRankingFragment` / H5 `from=gameTask`）。
    ///
    /// 独立于房间贡献/荣誉榜：`type` 仅支持 day/week，右侧显示 `expectedReward`。
    /// `expectedReward` 是字符串化 Long，由 `PartyGameTaskRankingResponse` 原样保留。
    static func gameTaskRanking(
        type: String,
        page: Int,
        size: Int
    ) async throws -> PartyGameTaskRankingResponse {
        let data = try await PartyAPIClient.shared.post(
            "/sapi/marketing/v1/client/gameTask/getRanking",
            body: ["type": type, "page": page, "size": size]
        )
        return try decoder.decode(PartyGameTaskRankingResponse.self, from: data)
    }

    /// Party 房 Weekly Task：宝石目标进度和礼物流水。Android 以礼物 `createTime` 作为 Long 分页游标。
    static func weeklyTaskInfo(pageSize: Int = 20, offset: Int64 = 0) async throws -> PartyWeeklyTaskPage {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/task/getTaskInfo",
            body: ["pageSize": pageSize, "offset": offset]
        )
        #if DEBUG
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        AppLogger.party.debug("[PartyWeeklyTask] getTaskInfo raw=\(raw, privacy: .private)")
        #endif
        return try PartyWeeklyTaskPage.decode(from: data)
    }

    /// 安卓主播端热门房任务检测。进房后和房间存活期间调用；仅服务端确认 TopX 时才显示任务入口。
    static func hotRoomTaskStatus(roomId: String) async throws -> PartyHotRoomTaskStatus {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/checkExistHot3",
            body: ["roomId": roomId]
        )
        #if DEBUG
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        AppLogger.party.debug("[PartyHotTask] checkExistHot3 raw=\(raw, privacy: .private)")
        #endif
        return try PartyHotRoomTaskStatus.decode(from: data)
    }

    /// 安卓热门任务规则页配置。后台下发的是规则图片地址，未配置时调用方保留本地规则兜底。
    static func hotRoomTaskRuleImageURL() async throws -> String? {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getRulePageConfig",
            body: [:]
        )
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let directURL = URL(string: raw),
           let scheme = directURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return raw
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = PartyWeeklyTaskPage.firstObject(
            in: PartyWeeklyTaskPage.unwrappedPayload(from: root),
            keys: ["rulePageConfig", "config"]
        ) ?? PartyWeeklyTaskPage.unwrappedPayload(from: root)
        return PartyWeeklyTaskPage.firstString(
            in: payload,
            keys: ["imageUrl", "imgUrl", "picUrl", "ruleImage", "rulePageImage", "ruleContent", "url"]
        )
    }

    /// 非热门房任务引导的目标房间。安卓在 `path == top_room_guide` 时调用此接口。
    static func hotRoomWithAvailableSeat() async throws -> PartyHotRoomGuide? {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/top/availableSeat",
            body: [:]
        )
        #if DEBUG
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        AppLogger.party.debug("[PartyHotTask] availableSeat raw=\(raw, privacy: .private)")
        #endif
        return try PartyHotRoomGuide.decode(from: data)
    }

    /// 热门任务露脸检测上报。Android 调用只传房间、截图 OSS URL 与当前麦位；
    /// 违规次数由服务端判定，随后由 `checkExistHot3` 刷新。
    static func reportHotRoomTask(
        roomId: String,
        content: String,
        seatIndex: Int
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/partyRoomReport",
            body: [
                "roomId": roomId,
                "content": content,
                "seatIndex": seatIndex,
            ]
        )
    }

    /// 分享面板的关注/粉丝联系人。对齐 H5 `apiPartyGetFollowInfoList`。
    /// `followType`: 0=我关注，1=关注我的；分页从 1 开始。
    static func shareFollowUsers(followType: Int, pageIndex: Int = 1, pageSize: Int = 20) async throws -> [PartyShareRecipient] {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getFollowInfoList",
            body: ["followType": followType, "pageIndex": pageIndex, "pageSize": pageSize]
        )
        return try decodeArrayOrEmpty(data, as: PartyShareRecipient.self)
    }

    /// 对齐 H5 `apiPartyInviteUserRoom`：站内邀请用户进入当前 Party 房。
    static func inviteUsersToRoom(roomId: String, yxAccidList: [String]) async throws {
        guard !yxAccidList.isEmpty else { return }
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/inviteUserRoom",
            body: ["roomId": roomId, "inviteYxAccIds": yxAccidList]
        )
    }

    /// 通知服务端播放当前用户进入 Party 房的效果。
    /// 对齐 H5 `apiPartyOpenEffect({ type: 2, roomId })`：RTC 与聊天室均加入成功后触发，
    /// 由服务端向同房用户广播座驾/进场效果。
    static func openEnterEffect(roomId: String) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/openEffect",
            body: ["type": 2, "roomId": roomId]
        )
    }

    /// 空麦位的在线推荐用户列表。对齐 H5 `apiGetRecommendInviteList`。
    static func recommendedSeatInviteUsers(
        roomId: String,
        offset: String? = nil,
        pageSize: Int = 20
    ) async throws -> [PartySeatInviteCandidate] {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getRecommendInviteList",
            body: ["roomId": roomId, "offset": offset ?? NSNull(), "pageSize": pageSize]
        )
        return try decodeArrayOrEmpty(data, as: PartySeatInviteCandidate.self)
    }

    /// 视频位邀请普通用户上麦。服务端向目标用户下发 1040，目标确认后才实际占位。
    static func inviteOnSeat(
        roomId: String,
        yxRoomId: String,
        seatIndex: Int,
        targetUserId: String,
        roomTempId: Int
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/inviteOnSeat",
            body: [
                "roomId": roomId,
                "yxRoomId": yxRoomId,
                "seatIndex": seatIndex,
                "targetUserId": targetUserId,
                "operatorType": 1,
                "roomTempId": roomTempId,
            ]
        )
    }

    /// Rank 接口特化解码：优先 `{rankList, myRank, duration}`，其次直接数组，再次 wrapper key 兜底。
    private static func decodeRankResponse(_ data: Data) throws -> PartyRankResponse {
        // 1. 直接对象 `{rankList: [...]}`
        if let obj = try? decoder.decode(PartyRankResponse.self, from: data) {
            return obj
        }
        // 2. envelope 分页数组 fallback（复用 decodeArrayOrEmpty）
        return PartyRankResponse(rankList: try decodeArrayOrEmpty(data, as: PartyRankEntry.self))
    }

    // MARK: - lock room (E spec §3 Lock Room)

    /// 房间加/解锁（E spec §3）。对齐 H5 `apiPartylockRoom`（`src/api/party/index.ts:177`）。
    ///
    /// **path**：`/sapi/weidou/v1/client/party/room/lockRoom`
    /// **加锁 payload**：`{ roomId: Int64, password: "1234", lockRoomFlag: 1 }`（H5 硬编码 4 位数字）
    /// **解锁 payload**：`{ roomId: Int64, lockRoomFlag: 0 }`（password 字段省略，对齐 H5 `feachLockRoom({ lockFlag: 0 })`）
    ///
    /// - **字段名 `lockRoomFlag`（非 `lockFlag`）**：对齐 H5 payload 字面（spec §0 校验点）
    /// - **roomId Int64**：H5 用户端 `roomId * 1` 数字化，与 sendGift 同款陷阱（避免后端 400）
    /// - **response 无 lockFlag 回填**：客户端本地乐观更新 `roomInfo.lockFlag`（对齐 H5）
    /// - **无 IM 广播**：加锁瞬间已在房观众不 kick；跨端一致靠 `enterRoom` 拦截返 10006 触发密码弹窗
    ///
    /// truthy 即成功（对齐 setBgImages / switchRoomTemp pattern）；envelope `code!='0000'` 由
    /// PartyAPIClient 抛 PartyAPIError.business，调用方转 error toast。
    static func lockRoom(roomId: String, password: String?) async throws {
        var body: [String: Any] = [
            "lockRoomFlag": password == nil ? 0 : 1,
        ]
        // roomId 数字化（H5 `id * 1` 对齐）—— fallback 到 String 兼容非数字 id 极端场景
        if let roomIdInt = Int64(roomId) {
            body["roomId"] = roomIdInt
        } else {
            body["roomId"] = roomId
        }
        if let password = password {
            body["password"] = password
        }
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/lockRoom",
            body: body
        )
    }

    /// 创建房间。MVP 仅传 roomName + roomTempId；其他可选字段 F 期补 UI。
    static func createRoom(
        roomName: String,
        roomAvatar: String? = nil,
        greetingMessage: String? = nil,
        roomLanguage: String? = nil,
        roomTempId: Int,
        bgImgId: Int? = nil
    ) async throws -> PartyRoomInfo {
        var body: [String: Any] = [
            "roomName": roomName,
            "roomTempId": roomTempId,
        ]
        if let v = roomAvatar { body["roomAvatar"] = v }
        if let v = greetingMessage { body["greetingMessage"] = v }
        if let v = roomLanguage { body["roomLanguage"] = v }
        if let v = bgImgId { body["bgImgId"] = v }
        let data = try await PartyAPIClient.shared.post("\(pathPrefix)/room/create", body: body)
        return try decodeObject(data, as: PartyRoomInfo.self)
    }

    /// 房间列表（大厅）。游标分页：snapshotId 锁列表快照 + offset 翻页。
    ///
    /// 3 个 tab 走 3 个 endpoint（对齐 H5 用户端 `src/api/party/index.ts` L21/24/27）：
    /// - `.party`    → `/party/room/list`
    /// - `.followed` → `/party/room/followed/list`
    /// - `.recent`   → `/party/room/recent/list`
    /// 参数结构完全一致；Follow/Recent 强制不筛语言（H5 index.vue L96 语义：`tabIndex===0 ? languageCode : null`）。
    static func roomList(
        kind: PartyRoomListKind = .party,
        languageCode: String? = nil,
        snapshotId: String? = nil,
        offset: Int? = nil,
        pageSize: Int = 20,
        queryParam: String? = nil,
        version: String = "v2"
    ) async throws -> [PartyRoomInfo] {
        var body: [String: Any] = [
            "pageSize": pageSize,
            "version": version,
        ]
        if let v = languageCode { body["languageCode"] = v }
        if let v = snapshotId { body["snapshotId"] = v }
        if let v = offset { body["offset"] = v }
        if let v = queryParam { body["queryParam"] = v }
        let data = try await PartyAPIClient.shared.post("\(pathPrefix)\(kind.endpointSuffix)", body: body)
        let rooms = try decodeArrayOrEmpty(data, as: PartyRoomInfo.self)
        // v7 诊断（2026-07-14）：后端可能对主播端账号返 [] —— 打 log 让真机能确认到底是 rooms=[] 还是 decode 失败
        // rawPreview 是 AES 解密后明文；Release 打脱敏
        let rawPreview = String(data: data, encoding: .utf8) ?? "<binary>"
        AppLogger.party.info("[PartyAPI] roomList kind=\(kind.endpointSuffix, privacy: .public) count=\(rooms.count) raw=\(rawPreview, privacy: .private)")
        return rooms
    }

    /// 我的派对房 + 家族信息（H5 `apiGetPartyRoomInfo`）。无 body，返回可能为 null/空对象（视为无 room）。
    /// 用于大厅浮动按钮"Create Room / My Room"分流：有 `myRoom.id` 且 `roomStatus != 2` → 显示 My Room。
    static func getMyRoomAndFamilyInfo() async throws -> PartyMyRoomInfoWrapper? {
        let data = try await PartyAPIClient.shared.post("\(pathPrefix)/room/getMyRoomAndFamilyInfo", body: [:])
        // 后端可能返回空对象/null——统一收敛为 nil
        do {
            return try decodeObject(data, as: PartyMyRoomInfoWrapper.self)
        } catch {
            return nil
        }
    }

    /// 拉用户基础信息（对齐 H5 `apiPartyGetUser({userId})`）。
    /// endpoint 特殊：**不带 pathPrefix `/party` 段**（H5 是 `/sapi/weidou/v1/client/user/get`），
    /// 因此显式拼绝对 path 而非 `pathPrefix+/room/...` 模式。
    /// 主播端派对房用途：拉房主 ownerInfo → `headFrameSmallImg` 装饰顶部头像框。
    static func getUserBasicInfo(userId: Int) async throws -> PartyUserBasicInfo? {
        let data = try await PartyAPIClient.shared.post(
            "/sapi/weidou/v1/client/user/get",
            body: ["userId": userId]
        )
        // 后端可能返回 null / 空对象（用户已注销等）—— 静默降级 nil
        do {
            return try decodeObject(data, as: PartyUserBasicInfo.self)
        } catch {
            return nil
        }
    }

    /// 进房。`isAnchor` 主播端固定 true。
    ///
    /// F-spec raw log：排查后端 `partyPrivateCallOpen / partyCallGiftId` 字段是否真实返回
    /// （agent-recon-field-names-unverified rule；对齐 getRoomBgImage 同款 pattern）
    static func enterRoom(roomId: String, password: String? = nil) async throws -> PartyRoomInfo {
        var body: [String: Any] = [
            "roomId": roomId,
            "isAnchor": true,
        ]
        if let v = password { body["password"] = v }
        let data = try await PartyAPIClient.shared.post("\(pathPrefix)/room/enter", body: body, suppressCodes: roomBusinessSuppress)
        // F-spec 真机 log：查后端是否在 enter 响应里返 partyPrivateCallOpen / partyCallGiftId 两字段
        let rawPreview = String(data: data, encoding: .utf8) ?? "<binary>"
        AppLogger.party.info("[PartyAPI] enterRoom raw=\(rawPreview, privacy: .private)")
        let info = try decodeObject(data, as: PartyRoomInfo.self)
        AppLogger.party.info("[PartyAPI] enterRoom decoded rewardQuantity=\(String(describing: info.rewardQuantity), privacy: .public) partyPrivateCallOpen=\(String(describing: info.partyPrivateCallOpen), privacy: .public) partyCallGiftId=\(info.partyCallGiftId ?? "nil", privacy: .public) partyCallGiftImg=\(info.partyCallGiftImg ?? "nil", privacy: .public) partyCallGiftPrice=\(String(describing: info.partyCallGiftPrice), privacy: .public) onSeatApplySwitch=\(String(describing: info.onSeatApplySwitch), privacy: .public)")
        return info
    }

    /// 删除 Party 房公屏文本消息。仅房主、房管和平台管理员可调用。
    /// 对齐 H5 `apiDeletePartyMsg`：`POST /party/msg/delete`。
    static func deletePartyMessage(
        roomId: String,
        messageId: String,
        timetag: Int64,
        fromAccid: String
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/msg/delete",
            body: [
                "roomId": roomId,
                "msgIdServer": messageId,
                "msgTimetag": timetag,
                "fromAccid": fromAccid,
            ]
        )
    }

    // MARK: - Backpack Gifts

    /// Party 背包库存。库存属于主 API 域，但必须带 `PARTY_GIFT` 场景；否则后端返回的
    /// `sendable` 与 Party 的显示范围不一致。
    static func partyBackpack(page: Int, pageSize: Int = 50) async throws -> PartyBackpackPage {
        let data = try await APIClient.shared.post(
            "/api/gift/backpack/list",
            body: [
                "scene": "PARTY_GIFT",
                "page": page,
                "pageSize": pageSize,
            ]
        )
        // H5 已兼容标准分页对象和裸数组两种实际返回；裸数组满页时继续翻页。
        if let list = try? decoder.decode([PartyBackpackGift].self, from: data) {
            return PartyBackpackPage(list: list, hasMore: list.count >= pageSize)
        }
        return try decodeObject(data, as: PartyBackpackPage.self)
    }

    /// 从背包向 Party 当前选中的麦位送礼。服务端通过 2049 广播礼物效果和公屏记录，
    /// 因此客户端不本地伪造礼物事件。
    @discardableResult
    static func sendPartyBackpackGift(
        roomId: String,
        giftId: Int64,
        num: Int,
        yxAccidList: [String]
    ) async throws -> Int? {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/gift/sendGiftFromBackpack",
            body: [
                "roomId": roomId,
                "giftId": giftId,
                "num": num,
                "yxAccidList": yxAccidList,
            ]
        )
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return PartyValueNormalizer.intify(object["remainingQuantity"])
    }

    /// 退房。`seatIndex` 传当前在麦的位号；不在麦时传 -1（对齐安卓/H5）。
    static func exitRoom(roomId: String, seatIndex: Int, yxRoomId: String) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/exitRoom",
            body: [
                "roomId": roomId,
                "seatIndex": seatIndex,
                "yxRoomId": yxRoomId,
            ]
        )
    }

    // MARK: - seat

    static func seatList(roomId: String) async throws -> [PartyRoomSeat] {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/list",
            body: ["roomId": roomId]
        )
        return try decodeArrayOrEmpty(data, as: PartyRoomSeat.self)
    }

    /// 上麦。返回 micId 字符串（接口参考 §3.B 描述返回 String，实际语义 M2 联调时确认）。
    /// 错误码 `ROOM_SEAT_IS_OCCUPIED / ROOM_SEAT_EMPTY` 由上层 `PartyRoomErrorMapper` 映射后触发自动重拉对账。
    /// `roomTempId` **Int（后端 Long）**——安卓确认结果 §2.2：全系统 DTO 是 Long。
    /// 调用方从 `PartyRoomInfo.roomTempId(String?)` 转：`Int(info.roomTempId ?? "1") ?? 1`。
    /// 排队 vs 直接占座由服务端按"房内角色 + 申请开关"决定，调用方需能处理「已入队」返回。
    static func onSeat(roomId: String, seatIndex: Int, yxRoomId: String, roomTempId: Int) async throws -> String {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/onSeat",
            body: [
                "roomId": roomId,
                "seatIndex": seatIndex,
                "yxRoomId": yxRoomId,
                "roomTempId": roomTempId,
            ],
            suppressCodes: roomBusinessSuppress
        )
        if let s = try? decoder.decode(String.self, from: data) { return s }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func downSeat(roomId: String, seatIndex: Int, yxRoomId: String, roomTempId: Int) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/downSeat",
            body: [
                "roomId": roomId,
                "seatIndex": seatIndex,
                "yxRoomId": yxRoomId,
                "roomTempId": roomTempId,
            ],
            suppressCodes: roomBusinessSuppress
        )
    }

    /// 禁麦/解禁麦（房主/房管专用；对齐 H5 apiPartyProhibitSeat + usePartyHooks.js:1157 `feachProhibitSeat`）。
    /// - operatorType: **6=禁麦，7=解禁麦**（H5 硬编码 magic number；后端 DTO 强校验）
    /// - 切换 `seatMicrophoneEnabled` 服务端管理态，独立于用户自身 microphoneEnabled；空位也由服务端返回状态决定是否允许预设禁麦。
    /// - 成功后服务端下发 1008 updateMedia 广播全员（seat.seatMicrophoneEnabled 切换），前端不做乐观更新
    static func prohibitSeat(
        roomId: String,
        seatIndex: Int,
        yxRoomId: String,
        operatorType: Int,
        roomTempId: Int
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/prohibitSeat",
            body: [
                "roomId": roomId,
                "seatIndex": seatIndex,
                "yxRoomId": yxRoomId,
                "operatorType": operatorType,
                "roomTempId": roomTempId,
            ]
        )
    }

    /// 抱下麦(仅"抱下"分支;抱上走 seat-invite 流程)。对齐 H5 `feachHoldSeat({operatorType: 3, seatIndex, targetUserId})`
    /// + `apiPartyHoldSeat` (`/sapi/weidou/v1/client/party/seat/holdSeat`)
    /// - operatorType 3 = 抱下麦(主态无 toast,被抱下者收 IM "You're off mic.")
    static func holdSeat(
        roomId: String,
        seatIndex: Int,
        targetUserId: String,
        yxRoomId: String,
        operatorType: Int,
        roomTempId: Int
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/holdSeat",
            body: [
                "roomId": roomId,
                "seatIndex": seatIndex,
                "targetUserId": targetUserId,
                "yxRoomId": yxRoomId,
                "operatorType": operatorType,
                "roomTempId": roomTempId,
            ]
        )
    }

    /// 设置/移除房管(仅房主可操作)。对齐 H5 `apiPartySetAdmin({roomId, userId, operationType})`
    /// (`/sapi/weidou/v1/client/party/room/setAdmin`)
    /// - operationType 1 = 添加房管, 2 = 移除房管
    static func setAdmin(
        roomId: String,
        userId: String,
        operationType: Int
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/setAdmin",
            body: [
                "roomId": roomId,
                "userId": userId,
                "operationType": operationType,
            ]
        )
    }

    /// 踢出房间。对齐 H5 `feachKickOutRoom({seatIndex, targetUserId, banType})`
    /// + `apiPartyKickOutRoom` (`/sapi/weidou/v1/client/party/room/kickOutRoom`)
    /// - banType 1 = 有限时长(kickOutInterval 秒), 2 = 永久
    /// - seatIndex -1 = 目标不在麦位;>=0 = 目标麦位号
    static func kickOutRoom(
        roomId: String,
        yxRoomId: String,
        seatIndex: Int,
        targetUserId: String,
        banType: Int
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/kickOutRoom",
            body: [
                "roomId": roomId,
                "yxRoomId": yxRoomId,
                "seatIndex": seatIndex,
                "targetUserId": targetUserId,
                "banType": banType,
            ]
        )
    }

    /// 锁麦/解锁麦（房主/房管专用；对齐 H5 apiPartylockSeat + usePartyHooks.js:1205 `feachLockSeat`）。
    /// - operatorType: **8=锁麦，9=解锁**（H5 硬编码 magic number；后端 DTO 强校验）
    /// - 只作用于**空位**（有人时后端会拒；调用方需前置校验）
    /// - 成功后服务端下发 1001 seat/update 广播全员（seat.lockFlag 切换），前端不做乐观更新
    static func lockSeat(
        roomId: String,
        seatIndex: Int,
        yxRoomId: String,
        operatorType: Int,
        roomTempId: Int
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/lockSeat",
            body: [
                "roomId": roomId,
                "seatIndex": seatIndex,
                "yxRoomId": yxRoomId,
                "operatorType": operatorType,
                "roomTempId": roomTempId,
            ]
        )
    }

    /// 切麦：从当前麦位切到目标 seatIndex（对齐 H5 apiPartyExchangeSeat + usePartyHooks.js:1322）。
    /// - operatorType 固定 10（H5 硬编码）
    /// - seatType 传目标麦位的 seatType（1=video / 2=voice）
    /// 成功后服务端下发 1001 seat/update 广播全员，前端等 seatList 更新，不做乐观。
    static func exchangeSeat(
        roomId: String,
        seatIndex: Int,
        yxRoomId: String,
        seatType: Int,
        roomTempId: Int
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/exchangeSeat",
            body: [
                "roomId": roomId,
                "seatIndex": seatIndex,
                "yxRoomId": yxRoomId,
                "operatorType": 10,
                "seatType": seatType,
                "roomTempId": roomTempId,
            ],
            suppressCodes: roomBusinessSuppress
        )
    }

    /// 切换麦克风/摄像头开关。`type: 1=麦克风 / 2=摄像头 / 3=麦+摄像头`（安卓确认 §2.3）。
    /// 服务端成功后下发 NIM `1008 PARTY_ROOM_UPDATE_MEDIA` 广播全员（M3 内分发）。
    /// `enable` Int 0/1（安卓确认 §2.3 后端 DTO 是 Integer）。
    /// 安卓接受视频位邀请后调 `updateMedia(type=3, enable=1)` 自动开摄像头。
    static func updateMedia(roomId: String, seatIndex: Int, type: Int, enable: Bool, yxRoomId: String) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/updateMedia",
            body: [
                "roomId": roomId,
                "seatIndex": seatIndex,
                "type": type,
                "enable": enable ? 1 : 0,
                "yxRoomId": yxRoomId,
            ]
        )
    }

    /// 响应视频位邀请（安卓确认 §3.8）。1040 弹窗后必须走此接口（**不是直接 onSeat**）。
    /// `action`: 1=接受 / 2=拒绝 / 3=超时；接受时后端内部置 byInvite=true 直接 doOnSeat（绕过排队与等级校验）。
    /// 接受成功后客户端再调 `updateMedia(type=3, enable=1)` 自动开摄像头。
    static func respondInvite(
        roomId: String,
        yxRoomId: String,
        seatIndex: Int,
        inviteId: String,
        action: Int,
        roomTempId: Int
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/respondInvite",
            body: [
                "roomId": roomId,
                "yxRoomId": yxRoomId,
                "seatIndex": seatIndex,
                "inviteId": inviteId,
                "action": action,
                "roomTempId": roomTempId,
            ]
        )
    }

    // MARK: - MC Seat (E spec §3, 2026-07-14)

    /// 设置接待位 MC Seat（E spec §3）。对齐 H5 `apiSetHostSeat`。
    ///
    /// **path**：`/sapi/weidou/v1/client/party/seat/setHostSeat`
    /// **body**：`{ roomId, seatIndex, yxRoomId, roomTempId }`
    ///
    /// - 权限：Owner / PlatformAdmin（后端强校验；前端 tools sheet 已门控）
    /// - 全房至多 1 个 MC 位（服务端保证）；重复设置不同 seatIndex 时后端会自动清旧
    /// - 成功后服务端下发 1001 seat/update 广播 → 前端 seatList 全量替换自然刷新
    /// - **字段名/method/path 未真机验证**（agent-recon-field-names-unverified rule）；
    ///   首次真机拉取后按 Console log 回写 alias 兜底
    static func setMCSeat(
        roomId: String,
        seatIndex: Int,
        yxRoomId: String,
        roomTempId: Int
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/setHostSeat",
            body: [
                "roomId": roomId,
                "seatIndex": seatIndex,
                "yxRoomId": yxRoomId,
                "roomTempId": roomTempId,
            ]
        )
    }

    /// 关闭接待位 MC Seat（E spec §3）。对齐 H5 `apiCloseHostSeat`。
    ///
    /// **path**：`/sapi/weidou/v1/client/party/seat/closeHostSeat`
    /// **body**：`{ roomId, yxRoomId, roomTempId }`（**无 seatIndex** —— MC 全房唯一，服务端按 roomId 定位）
    ///
    /// - 权限：Owner / PlatformAdmin
    /// - 成功后服务端下发 1001 seat/update 广播 → 前端 seatList 全量替换自然刷新
    /// - 无二次确认由 UI 层遵循（对齐 H5）
    static func closeMCSeat(
        roomId: String,
        yxRoomId: String,
        roomTempId: Int
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/closeHostSeat",
            body: [
                "roomId": roomId,
                "yxRoomId": yxRoomId,
                "roomTempId": roomTempId,
            ]
        )
    }

    // MARK: - room mode (E v2 §1)

    /// 切换房间模板（Room Mode 切模式）。spec §1 契约。
    /// 对齐 H5 `apiSwitchRoomTemp({roomId, roomTempId, yxRoomId})`。
    /// 无字段消费；truthy 即成功。房主本地兜底：成功后立即调 `handleRoomModeChanged`，
    /// 不等 IM 1017（云信可能不发自己回执），观众端走 IM 到达路径 + `roomTempId==newTempId` 幂等。
    static func switchRoomTemp(roomId: String, roomTempId: Int, yxRoomId: String) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/switchRoomTemp",
            body: [
                "roomId": roomId,
                "roomTempId": roomTempId,
                "yxRoomId": yxRoomId,
            ]
        )
    }

    // MARK: - mic application (E v2 §2)

    /// 拉排麦申请列表（房主/房管端 Mic Application 面板用）。spec §2 契约。
    /// 对齐 H5 `apiGetQueueSeatList({roomId, pageSize})`。
    /// `myIndex = -1` 表示当前用户不在列表；`totalNum` 队列总长度用于 badge / 系统消息计数。
    static func getQueueSeatList(roomId: String, pageSize: Int = 99) async throws -> PartyMicApplicationListResponse {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/getQueueSeatList",
            body: [
                "roomId": roomId,
                "pageSize": pageSize,
            ]
        )
        return try decodeObject(data, as: PartyMicApplicationListResponse.self)
    }

    /// 拒绝申请（房主/房管操作，spec §2）。对齐 H5 `apiRefuseQueueSeat`。
    /// 服务端成功后下发 1018 op=3 广播；申请者本地设 `rejectedAt = now` 触发 30s 冷却。
    static func refuseQueueSeat(roomId: String, targetUserId: String, yxRoomId: String) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/refuseQueueSeat",
            body: [
                "roomId": roomId,
                "targetUserId": targetUserId,
                "yxRoomId": yxRoomId,
            ]
        )
    }

    /// 通过申请（房主/房管操作，spec §2）。对齐 H5 `apiAgreeSeat`。
    /// - `seatIndex`：房主端挑首空位（排除 `pendingApproveSeatIndex` 已占位集合防并发冲突）
    /// - `operatorType`：房主端硬编 1；房管路径待真机验证后回填（spec §5 TODO）
    /// - 服务端成功后下发 1001/1012（麦位刷新）+ 1018 op=2（出队通知）组合，无独立"批准"广播
    static func agreeSeat(
        roomId: String,
        seatIndex: Int,
        targetUserId: String,
        operatorType: Int,
        roomTempId: Int,
        yxRoomId: String
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/agreeSeat",
            body: [
                "roomId": roomId,
                "seatIndex": seatIndex,
                "targetUserId": targetUserId,
                "operatorType": operatorType,
                "roomTempId": roomTempId,
                "yxRoomId": yxRoomId,
            ]
        )
    }

    /// 切换排麦申请开关（房主端，spec §2）。对齐 H5 `apiUpdateOnSeatEnable({roomId, enable})`。
    /// `enable: 0` 关闭 / `1` 开启；服务端成功后下发 1021 广播全员同步 `onSeatApplySwitch`。
    /// 首次切换需 UI 层前置协议弹窗（`partySaveInfo.autoEnterOn/OffApplication` = false 时）。
    static func updateOnSeatEnable(roomId: String, enable: Int) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/updateOnSeatEnable",
            body: [
                "roomId": roomId,
                "enable": enable,
            ]
        )
    }

    /// 观众放弃排麦（spec §2）。对齐 H5 `apiGiveUpQueueSeat({roomId, yxRoomId})`。
    /// 成功后本地清 `myApplyInfo.inIndex = 0` + toast；服务端下发 1018 op=4 广播。
    static func giveUpQueueSeat(roomId: String, yxRoomId: String) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/seat/giveUpQueueSeat",
            body: [
                "roomId": roomId,
                "yxRoomId": yxRoomId,
            ]
        )
    }

    // MARK: - blocklist (E spec §1，房主/房管房间维度黑名单)

    /// 拉房间黑名单列表（E spec §1）。对齐 H5 `apiGetKickOutBlacklist`。
    ///
    /// **path**：`/sapi/weidou/v1/client/party/room/getKickOutBlacklist`
    /// **body**：`{ roomId: Int }` —— roomId 传业务 db id（H5 `currentPartyInfo.id`，**非**云信 yxRoomId）
    /// **response**：**直接数组** `[PartyBlocklistItem]`（无 list/records 包装；spec §0 校验 point 2）
    ///
    /// 无分页（H5 全量拉，van-list 只做壳未配 finished/loading —— iOS 沿用全量策略，量级由后端保证）。
    static func getKickOutBlacklist(roomId: Int) async throws -> [PartyBlocklistItem] {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getKickOutBlacklist",
            body: ["roomId": roomId]
        )
        return try decodeArrayOrEmpty(data, as: PartyBlocklistItem.self)
    }

    /// 解除封禁（E spec §1）。对齐 H5 `apiRemoveKickOutBlacklist`。
    ///
    /// **path**：`/sapi/weidou/v1/client/party/room/removeKickOutBlacklist`
    /// **body**：`{ roomId: Int, targetUserId: String }`
    /// **response**：Bool（真为成功；后端可能返裸 `true` / envelope 包装 `{data: true}` / `{result: true}`）
    ///
    /// H5 存在 bug：`.then/.finally` 均弹"Removed successfully"，失败静默 —— iOS 修正走 error toast
    /// （spec §0 校验 point 6）。此方法失败抛异常由调用方转 error toast。
    ///
    /// 加/解黑本 spec 范围内**无 IM 广播**（H5 blocklist.vue 无订阅；spec §2）——调用成功后由 Store 层
    /// 乐观 filter 本地 items，其他管理员端下次开 popup 才见新态。
    static func removeKickOutBlacklist(roomId: Int, targetUserId: String) async throws -> Bool {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/removeKickOutBlacklist",
            body: [
                "roomId": roomId,
                "targetUserId": targetUserId,
            ]
        )
        // 1. 裸 Bool
        if let b = try? decoder.decode(Bool.self, from: data) { return b }
        // 2. 单层包装 {data|result|success: true}
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["data", "result", "success"] {
                if let v = dict[key] as? Bool { return v }
                if let n = dict[key] as? NSNumber { return n.boolValue }
            }
        }
        // 3. 字符串 "true" / "1"
        if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if s == "true" || s == "1" { return true }
            if s == "false" || s == "0" { return false }
        }
        // 4. 空 / 未识别 —— 后端 sapi envelope code==200 已由 PartyAPIClient 层过滤成功，
        //    到这里说明 HTTP 层成功但 body 无明确 Bool；默认视为成功
        return true
    }

    // MARK: - gift

    /// 派对房礼物架列表（H-5 · 对齐 H5 用户端 `apiPartyGetRoomGift`）。
    ///
    /// **path**: `/sapi/weidou/v1/client/party/gift/getPartyRoomGift`（sapi 域，与 sendGift 同域）
    /// **⚠️ 不走** `/api/gift/v3/getGiftList`（主接口不识别 PARTY_ROOM/PARTY_GIFT scene → parameter.error）
    ///
    /// **Request body**（H5 `stores/modules/party.js:1269-1272`）：
    /// - `showType`: 0=礼物架 / 1=底部栏（默认 0）
    /// - `apiVersion`: 2 触发后端 tabs[] 结构（灰度关闭时后端自动 v1 回退）
    ///
    /// **Response 结构**：`{tabs: [{tabCode, tabName, tabSort, gifts: [GiftListData]}]}`
    /// v1 兜底（`{giftInfoDtoList: {Popular: [...], ...}}`）由调用侧另作 fallback；本方法只识别 v2。
    static func getPartyRoomGift(showType: Int = 0, apiVersion: Int = 2) async throws -> PartyGiftV2Response {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/gift/getPartyRoomGift",
            body: [
                "showType": showType,
                "apiVersion": apiVersion,
            ]
        )
        return try decodeObject(data, as: PartyGiftV2Response.self)
    }

    /// 派对房送礼。`scene` 固定 "PARTY_ROOM"（对齐 H5 party-gift-popup.vue L417 字面值）。
    /// 服务端成功后下发 NIM `2049 RECEIVE_PARTY_ROOM_GIFT_COMPRESSED` 广播；
    /// 客户端按 2049 渲染（**不识别** 1007 老版双发，spec §1.2 决策）。
    ///
    /// **⚠️ roomId 类型陷阱**（2026-07-14 真机 400 修复）：H5 用户端 `partyStore.currentPartyInfo.id * 1` 把
    /// roomId 数字化再传（party-gift-popup.vue L419）。iOS 若传 String → JSON 序列化成 `"roomId":"1234567"`
    /// → 后端 code=400 "Illegal parameter"。**必须转 Int64 传数字**。
    static func sendGift(roomId: String, giftId: Int, num: Int, yxAccidList: [String]) async throws -> PartySendGiftResult {
        var body: [String: Any] = [
            "scene": "PARTY_ROOM",
            "giftId": giftId,
            "num": num,
            "yxAccidList": yxAccidList,
        ]
        // roomId 数字化（H5 `id * 1` 对齐）—— fallback 到 String 兼容非数字 id 极端场景
        if let roomIdInt = Int64(roomId) {
            body["roomId"] = roomIdInt
        } else {
            body["roomId"] = roomId
        }
        let data = try await PartyAPIClient.shared.post("\(pathPrefix)/gift/sendGift", body: body, suppressCodes: giftBusinessSuppress)
        return try decodeObject(data, as: PartySendGiftResult.self)
    }

    // MARK: - party call (F spec §4.3)

    /// 更新房间私 call 开关（房主设置弹窗调用）。对齐安卓 `HttpHelper.updatePartyPrivateCall`。
    ///
    /// **path**：`/sapi/weidou/v1/client/party/room/updatePartyPrivateCall`
    /// **body**：`{ roomId: String, enable: Int(0/1), giftId: String? }`
    ///
    /// - 权限：Owner / RoomAdmin / PlatformAdmin（后端强校验）
    /// - 关闭状态下用户端拨打时后端拦截，主播端不收 RTM VideoCall
    /// - 成功后可能下发 1029 payload `status=calling/ended` 更新其他客户端（本 spec 不做本地乐观回写）
    ///
    /// **⚠️ 字段名/method 未真机验证**（agent-recon-field-names-unverified rule）；
    /// Step 3 真机首次调用后按 log 补 alias 兼容。
    static func updatePartyPrivateCall(
        roomId: String,
        enable: Int,
        giftId: String? = nil
    ) async throws {
        var body: [String: Any] = [
            "roomId": roomId,
            "enable": enable,
        ]
        if let v = giftId { body["giftId"] = v }
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/updatePartyPrivateCall",
            body: body
        )
    }

    /// 拉私 call 礼物列表（房主设置弹窗内选礼物用）。对齐安卓 `ApiService.getPartyCallGiftList`。
    ///
    /// **真机 log 校准（2026-07-16）**：后端 response schema 与现有 `GiftListData` 完全一致
    /// （`id: String, name, giftPrice: String, giftSmallImg, giftImg, ...`），直接复用无需另建 model。
    ///
    /// **path**：`/sapi/weidou/v1/client/party/room/getPartyCallGiftList`
    /// **body**：`{ scene: Int }` —— `scene=2` 设置弹窗（本 spec 仅用此场景）；`scene=1` 通话内送礼（后续里程碑）
    /// **response**：`[GiftListData]`（复用现有礼物模型 · 已 String/Int64 双兼容 decode）
    static func getPartyCallGiftList(scene: Int = 2) async throws -> [GiftListData] {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getPartyCallGiftList",
            body: ["scene": scene]
        )
        return try decodeArrayOrEmpty(data, as: GiftListData.self)
    }

    // MARK: - Lucky Number (H5 party-tool-menu.vue / lucky-number-panel.vue)

    /// 拉取幸运数字配置。接口与 H5 `apiLuckyNumberGetConfig` 完全一致。
    static func getLuckyNumberConfig(roomId: String) async throws -> PartyLuckyNumberConfig? {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/lucky-number/getConfig",
            body: ["roomId": roomId]
        )
        guard String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) != "null" else {
            return nil
        }
        return try decodeObject(data, as: PartyLuckyNumberConfig.self)
    }

    /// 设置幸运数字范围、固定号码与管理员权限。`luckyNumber=nil` 对齐 H5 显式传 null，代表随机抽取。
    static func saveLuckyNumberConfig(
        roomId: String,
        numberRangeCode: Int,
        luckyNumber: Int?,
        adminCanSet: Bool?
    ) async throws -> PartyLuckyNumberConfig? {
        var body: [String: Any] = [
            "roomId": roomId,
            "numberRangeCode": numberRangeCode,
            // H5 API contract 是 string | null；保持类型一致，避免服务端 DTO 收紧时拒绝数字 JSON。
            "luckyNumber": luckyNumber.map(String.init) ?? NSNull(),
        ]
        if let adminCanSet {
            body["adminCanSet"] = adminCanSet ? 1 : 0
        }
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/lucky-number/saveConfig",
            body: body
        )
        guard String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) != "null" else {
            return nil
        }
        return try decodeObject(data, as: PartyLuckyNumberConfig.self)
    }

    /// 抽取幸运数字并由服务端广播到公屏（H5 `apiLuckyNumberGenerate`）。
    static func generateLuckyNumber(roomId: String) async throws -> Bool {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/lucky-number/generate",
            body: ["roomId": roomId]
        )
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) != "null"
    }

    /// 房主查看最近三天的幸运数字命中记录（H5 `apiLuckyNumberHistory`）。
    static func getLuckyNumberHistory(
        roomId: String,
        pageNo: Int = 1,
        pageSize: Int = 20
    ) async throws -> PartyLuckyNumberHistoryResponse {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/lucky-number/history",
            body: [
                "roomId": roomId,
                "pageNo": String(pageNo),
                "pageSize": String(pageSize),
            ]
        )
        return try decodeObject(data, as: PartyLuckyNumberHistoryResponse.self)
    }

    // MARK: - room music (H5 room-mana-popup.vue)

    /// 读取房间音乐开关的真实状态。`roomMusicSwitc` 只表示音乐功能是否开放，
    /// 实际 ON/OFF 必须以 music/settings 返回的 `isEnabled` 为准。
    static func getMusicSettings(roomId: String) async throws -> PartyMusicSettings {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/music/settings",
            body: ["roomId": roomId]
        )
        return try decodeObject(data, as: PartyMusicSettings.self)
    }

    /// 房主或房管切换房间音乐。与 H5 `apiPartyMusicEnableMusic` 的参数保持一致。
    static func setMusicEnabled(roomId: String, yxRoomId: String, enabled: Bool) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/music/enableMusic",
            body: [
                "roomId": roomId,
                "isEnable": enabled ? 1 : 0,
                "yxRoomId": yxRoomId,
            ]
        )
    }

    /// H5 音乐面板的歌单列表。`musicType`：1=Playlist、2=Liked、3=Local。
    static func getMusicList(
        musicType: Int,
        pageSize: Int = 20,
        offset: String? = nil
    ) async throws -> [PartyMusicItem] {
        var body: [String: Any] = [
            "musicType": musicType,
            "pageSize": pageSize,
        ]
        if let offset { body["offset"] = offset }
        let data = try await PartyAPIClient.shared.post("\(pathPrefix)/music/list", body: body)
        return try decodeArrayOrEmpty(data, as: PartyMusicItem.self)
    }

    /// 收藏或取消收藏音乐。`type`：1=收藏、2=取消收藏。
    static func setMusicLiked(songId: String, musicType: Int, liked: Bool) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/music/like",
            body: [
                "songId": songId,
                "musicType": musicType,
                "type": liked ? 1 : 2,
            ]
        )
    }

    /// 管理员播放、暂停或切歌。参数与 H5 `apiPartyMusicPlay` 对齐。
    static func playMusic(
        songId: String,
        roomId: String,
        musicType: Int,
        playMode: Int,
        volume: Int,
        actionType: Int
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/music/play",
            body: [
                "songId": songId,
                "roomId": roomId,
                "musicType": musicType,
                "playMode": playMode,
                "volume": volume,
                "actionType": actionType,
            ]
        )
    }

    /// 更新当前歌曲的音量、播放模式或播放状态。
    static func updateMusic(
        songId: String,
        roomId: String,
        volume: Int,
        playMode: Int,
        playStatus: Int
    ) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/music/update",
            body: [
                "songId": songId,
                "roomId": roomId,
                "volume": volume,
                "playMode": playMode,
                "playStatus": playStatus,
            ]
        )
    }

    /// 添加房主本地上传的音乐。
    static func addLocalMusic(roomId: String, music: PartyLocalMusicUpload) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/music/uploadLocalMusic",
            body: [
                "roomId": roomId,
                "musicList": [[
                    "songName": music.songName,
                    "musicUrl": music.musicURL,
                    "durationSeconds": music.durationSeconds,
                    "fileFormat": music.fileFormat,
                ]],
            ]
        )
    }

    /// 删除房主本地上传的音乐。
    static func deleteLocalMusic(roomId: String, musicIDs: [String]) async throws {
        guard !musicIDs.isEmpty else { return }
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/music/removeLocalMusic",
            body: ["roomId": roomId, "musicIdList": musicIDs]
        )
    }

    // MARK: - emoji panel (F 里程碑 · 2026-07-17)

    /// 派对房表情面板分类列表（对齐 H5 `apiPartyEmojis` / `apiGetPartyRoomEmojis` ·
    /// `livechat-h5/src/api/party/index.ts:139` + `pay/index.ts:61`）。
    ///
    /// **path**：`/sapi/weidou/v1/client/party/room/getPartyRoomEmojis`（无入参）
    /// **response**：`[PartyEmojiClassification]`（每分类 `{classType, coverImage, emojisList}`）
    ///
    /// **H5 用 GET · iOS 用 POST**（对齐 [api-http-method-strict] rule 说明）：
    /// PartyAPIClient 只有 `post()`；H5 `src/api/party/index.ts:139` 明确后端两 verb 都接
    /// （POST 别名 `apiPartyEmojis` 与 GET `apiGetPartyRoomEmojis` 同 path），沿用 party 域一致 POST。
    ///
    /// **字段校验**：首次真机接入后按 log 复核 emojisList 内字段名 · 对齐
    /// [im-payload-real-log-over-code-assumption]（H5 侧 vue 消费的字段可能只是部分）
    static func getPartyRoomEmojis() async throws -> [PartyEmojiClassification] {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/room/getPartyRoomEmojis",
            body: [:]
        )
        return try decodeArrayOrEmpty(data, as: PartyEmojiClassification.self)
    }

    // MARK: - Super Wheel

    /// Party Super Wheel 的后台档位和玩法开关。
    static func superWheelConfig() async throws -> PartySuperWheelConfig {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/super-wheel/config",
            body: [:]
        )
        return try PartySuperWheelConfig.decode(from: data)
    }

    /// 读取当前房间进行中的转盘；服务端返回 JSON null 时代表没有对局。
    static func superWheelState(roomId: String) async throws -> PartySuperWheelState? {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/super-wheel/state",
            body: ["roomId": roomId]
        )
        return try PartySuperWheelState.decodeOptional(from: data)
    }

    @discardableResult
    static func openSuperWheel(roomId: String, entryFee: Int) async throws -> PartySuperWheelOpenResult {
        let data = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/super-wheel/open",
            body: ["roomId": roomId, "entryFee": entryFee],
            suppressCodes: ["11503"] // 已有对局：调用方静默转拉当前状态
        )
        return try PartySuperWheelOpenResult.decode(from: data)
    }

    static func joinSuperWheel(roundId: String) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/super-wheel/join",
            body: ["roundId": roundId]
        )
    }

    static func betSuperWheel(roundId: String, amount: Int) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/super-wheel/bet",
            body: ["roundId": roundId, "amount": amount]
        )
    }

    static func closeSuperWheel(roundId: String) async throws {
        _ = try await PartyAPIClient.shared.post(
            "\(pathPrefix)/super-wheel/close",
            body: ["roundId": roundId]
        )
    }
}

// MARK: - Super Wheel models

/// Super Wheel 接口的数据属于正在灰度的玩法，Long/金额字段会混发 Number 与 String。
/// 这里在边界处归一，UI 和 IM 广播只消费统一后的值。
struct PartySuperWheelConfig: Equatable {
    let enabled: Bool
    let entryFees: [Int]

    static func decode(from data: Data) throws -> Self {
        let object = try PartySuperWheelJSON.object(from: data)
        return Self(
            enabled: PartySuperWheelJSON.bool(object["enabled"]),
            entryFees: PartySuperWheelJSON.array(object["entryFees"])
                .compactMap(PartySuperWheelJSON.int)
                .filter { $0 > 0 }
        )
    }
}

struct PartySuperWheelOpenResult: Equatable {
    let roundId: String
    let entryFee: Int
    let state: Int

    static func decode(from data: Data) throws -> Self {
        let object = try PartySuperWheelJSON.object(from: data)
        guard let roundId = PartySuperWheelJSON.string(object["roundId"]), !roundId.isEmpty else {
            throw PartySuperWheelJSONError.missingRequiredField("roundId")
        }
        return Self(
            roundId: roundId,
            entryFee: PartySuperWheelJSON.int(object["entryFee"]) ?? 0,
            state: PartySuperWheelJSON.int(object["state"]) ?? 1
        )
    }
}

struct PartySuperWheelParticipant: Identifiable, Equatable {
    let userId: String
    let nickname: String?
    let avatar: String?
    var totalBet: Int64
    var status: Int
    let isHost: Bool

    var id: String { userId }

    static func from(_ object: [String: Any]) -> Self? {
        guard let userId = PartySuperWheelJSON.string(object["userId"]), !userId.isEmpty else { return nil }
        return Self(
            userId: userId,
            nickname: PartySuperWheelJSON.string(object["nickname"]),
            avatar: PartySuperWheelJSON.string(object["avatar"]),
            totalBet: Int64(PartySuperWheelJSON.int(object["totalBet"]) ?? 0),
            status: PartySuperWheelJSON.int(object["status"]) ?? 1,
            isHost: PartySuperWheelJSON.bool(object["host"])
        )
    }
}

struct PartySuperWheelUser: Equatable {
    let userId: String
    let nickname: String?
    let avatar: String?

    static func from(_ object: [String: Any]?) -> Self? {
        guard let object,
              let userId = PartySuperWheelJSON.string(object["userId"]), !userId.isEmpty else { return nil }
        return Self(
            userId: userId,
            nickname: PartySuperWheelJSON.string(object["nickname"]),
            avatar: PartySuperWheelJSON.string(object["avatar"])
        )
    }
}

struct PartySuperWheelState: Equatable {
    var roundId: String
    var roomId: String
    var hostId: String?
    var entryFee: Int
    var state: Int
    var roundNo: Int
    var totalPool: Int64
    var phaseDeadlineMs: Int64?
    var participants: [PartySuperWheelParticipant]
    var winnerId: String?
    var winner: PartySuperWheelUser?
    var winnerAmount: Int64?
    var revealUser: PartySuperWheelUser?
    var remainCount: Int?

    static func decodeOptional(from data: Data) throws -> Self? {
        let trimmed = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "null" else { return nil }
        return try from(PartySuperWheelJSON.object(from: data))
    }

    static func from(_ object: [String: Any]) throws -> Self {
        guard let roundId = PartySuperWheelJSON.string(object["roundId"]), !roundId.isEmpty else {
            throw PartySuperWheelJSONError.missingRequiredField("roundId")
        }
        let participants = PartySuperWheelJSON.array(object["participants"])
            .compactMap { $0 as? [String: Any] }
            .compactMap(PartySuperWheelParticipant.from)
        let winner = PartySuperWheelUser.from(object["winner"] as? [String: Any])
        let winnerId = PartySuperWheelJSON.string(object["winnerId"]) ?? winner?.userId
        let resolvedWinner = winner ?? participants.first(where: { $0.userId == winnerId }).map {
            PartySuperWheelUser(userId: $0.userId, nickname: $0.nickname, avatar: $0.avatar)
        }
        return Self(
            roundId: roundId,
            roomId: PartySuperWheelJSON.string(object["roomId"]) ?? "",
            hostId: PartySuperWheelJSON.string(object["hostId"]),
            entryFee: PartySuperWheelJSON.int(object["entryFee"]) ?? 0,
            state: PartySuperWheelJSON.int(object["state"]) ?? 0,
            roundNo: PartySuperWheelJSON.int(object["roundNo"])
                ?? PartySuperWheelJSON.int(object["currentRoundNo"]) ?? 0,
            totalPool: Int64(PartySuperWheelJSON.int(object["totalPool"]) ?? 0),
            phaseDeadlineMs: PartySuperWheelJSON.int64(object["phaseDeadline"]),
            participants: participants,
            winnerId: winnerId,
            winner: resolvedWinner,
            winnerAmount: PartySuperWheelJSON.int64(object["winnerAmount"]),
            revealUser: PartySuperWheelUser.from(object["eliminatedUser"] as? [String: Any]),
            remainCount: PartySuperWheelJSON.int(object["remainCount"])
        )
    }
}

private enum PartySuperWheelJSONError: Error {
    case missingRequiredField(String)
}

private enum PartySuperWheelJSON {
    static func object(from data: Data) throws -> [String: Any] {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PartySuperWheelJSONError.missingRequiredField("object")
        }
        for key in ["data", "result"] {
            if let nested = raw[key] as? [String: Any] { return nested }
        }
        return raw
    }

    static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String, !string.isEmpty { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func int64(_ value: Any?) -> Int64? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let int = int(value) { return int != 0 }
        if let string = value as? String { return ["true", "yes", "on"].contains(string.lowercased()) }
        return false
    }

    static func array(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
}

/// Party 大厅 banner。字段对齐 H5 `homeBanner.vue`：普通活动 URL、游戏以及指定 Party 房三种点击分支。
struct PartyHomeBanner: Decodable, Identifiable, Equatable {
    let id: String
    let picUrl: String?
    let directUrl: String?
    let clickType: Int
    let gameLink: String?
    let partyRoomId: String?

    private enum CodingKeys: String, CodingKey {
        case id, picUrl, directUrl, clickType, gameLink, partyRoomId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? c.decode(String.self, forKey: .id), !value.isEmpty {
            id = value
        } else if let value = try? c.decode(Int64.self, forKey: .id) {
            id = String(value)
        } else {
            id = UUID().uuidString
        }
        picUrl = try? c.decode(String.self, forKey: .picUrl)
        directUrl = try? c.decode(String.self, forKey: .directUrl)
        if let value = try? c.decode(Int.self, forKey: .clickType) {
            clickType = value
        } else if let value = try? c.decode(String.self, forKey: .clickType), let parsed = Int(value) {
            clickType = parsed
        } else {
            clickType = 0
        }
        gameLink = try? c.decode(String.self, forKey: .gameLink)
        if let value = try? c.decode(String.self, forKey: .partyRoomId) {
            partyRoomId = value
        } else if let value = try? c.decode(Int64.self, forKey: .partyRoomId) {
            partyRoomId = String(value)
        } else {
            partyRoomId = nil
        }
    }

    /// 复用首页 `LiveBanner` 时，房间/游戏点击没有标准 directUrl，使用非空哨兵令该页保持可点击。
    var liveBannerItem: AppPictureItem {
        let tapURL = directUrl ?? gameLink ?? (partyRoomId == nil ? nil : "party://room/\(partyRoomId!)")
        return AppPictureItem(id: id, picUrl: picUrl, directUrl: tapURL)
    }
}

/// H5 `currentMusicInfo` 的宽容解码版本。音乐状态会同时通过 HTTP 和 1011/1013 IM 下发，
/// 数字/布尔字段可能在环境间混发 String、Int 与 Bool。
struct PartyMusicSettings: Decodable, Equatable {
    let id: String?
    let currentSongId: String?
    let songName: String?
    let musicType: Int
    let playStatus: Int
    let volume: Int
    let playMode: Int
    let isEnabled: Bool

    static let empty = PartyMusicSettings(
        id: nil, currentSongId: nil, songName: nil, musicType: 1,
        playStatus: 0, volume: 100, playMode: 1, isEnabled: false
    )

    init(
        id: String?,
        currentSongId: String?,
        songName: String?,
        musicType: Int,
        playStatus: Int,
        volume: Int,
        playMode: Int,
        isEnabled: Bool
    ) {
        self.id = id
        self.currentSongId = currentSongId
        self.songName = songName
        self.musicType = musicType
        self.playStatus = playStatus
        self.volume = volume
        self.playMode = playMode
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, currentSongId, songId, songName, musicType, playStatus, volume, playMode, isEnabled, isEnable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = Self.string(c, key: .id)
        currentSongId = Self.string(c, key: .currentSongId) ?? Self.string(c, key: .songId)
        songName = try? c.decode(String.self, forKey: .songName)
        musicType = Self.int(c, key: .musicType) ?? 1
        playStatus = Self.int(c, key: .playStatus) ?? 0
        volume = min(max(Self.int(c, key: .volume) ?? 100, 0), 200)
        playMode = Self.int(c, key: .playMode) ?? 1
        isEnabled = Self.bool(c, key: .isEnabled) || Self.bool(c, key: .isEnable)
    }

    func updating(
        currentSongId: String? = nil,
        songName: String? = nil,
        musicType: Int? = nil,
        playStatus: Int? = nil,
        volume: Int? = nil,
        playMode: Int? = nil,
        isEnabled: Bool? = nil
    ) -> Self {
        Self(
            id: id,
            currentSongId: currentSongId ?? self.currentSongId,
            songName: songName ?? self.songName,
            musicType: musicType ?? self.musicType,
            playStatus: playStatus ?? self.playStatus,
            volume: min(max(volume ?? self.volume, 0), 200),
            playMode: playMode ?? self.playMode,
            isEnabled: isEnabled ?? self.isEnabled
        )
    }

    func applying(payload: [String: Any]) -> Self {
        var next = self
        if payload["currentSongId"] != nil || payload["songId"] != nil {
            next = next.updating(currentSongId: PartyValueNormalizer.stringify(payload["currentSongId"] ?? payload["songId"]))
        }
        if let name = PartyValueNormalizer.stringify(payload["songName"]) {
            next = next.updating(songName: name)
        }
        if let type = PartyValueNormalizer.intify(payload["musicType"]) {
            next = next.updating(musicType: type)
        }
        if let status = PartyValueNormalizer.intify(payload["playStatus"]) {
            next = next.updating(playStatus: status)
        }
        if let value = PartyValueNormalizer.intify(payload["volume"]) {
            next = next.updating(volume: value)
        }
        if let mode = PartyValueNormalizer.intify(payload["playMode"]) {
            next = next.updating(playMode: mode)
        }
        if payload["isEnabled"] != nil || payload["isEnable"] != nil {
            let raw = payload["isEnabled"] ?? payload["isEnable"]
            let enabled = PartyValueNormalizer.intify(raw) == 1
                || (PartyValueNormalizer.stringify(raw)?.lowercased() == "true")
            next = next.updating(isEnabled: enabled)
        }
        return next
    }

    private static func string(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> String? {
        if let value = try? c.decode(String.self, forKey: key), !value.isEmpty { return value }
        if let value = try? c.decode(Int64.self, forKey: key) { return String(value) }
        return nil
    }

    private static func int(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Int? {
        if let value = try? c.decode(Int.self, forKey: key) { return value }
        if let value = try? c.decode(String.self, forKey: key) { return Int(value) }
        return nil
    }

    private static func bool(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Bool {
        if let value = try? c.decode(Bool.self, forKey: key) { return value }
        if let value = int(c, key: key) { return value == 1 }
        if let value = try? c.decode(String.self, forKey: key) {
            return value == "1" || value.lowercased() == "true"
        }
        return false
    }
}

struct PartyMusicItem: Decodable, Equatable, Identifiable {
    let id: String
    let songName: String
    let durationSeconds: Int
    let sortWeight: String?
    let musicType: Int
    let isLiked: Bool

    private enum CodingKeys: String, CodingKey { case id, songName, durationSeconds, sortWeight, musicType, like }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = Self.string(c, key: .id) ?? UUID().uuidString
        songName = (try? c.decode(String.self, forKey: .songName)) ?? ""
        durationSeconds = Self.int(c, key: .durationSeconds) ?? 0
        sortWeight = Self.string(c, key: .sortWeight)
        musicType = Self.int(c, key: .musicType) ?? 1
        isLiked = Self.bool(c, key: .like)
    }

    func updating(isLiked: Bool) -> Self {
        Self(id: id, songName: songName, durationSeconds: durationSeconds, sortWeight: sortWeight, musicType: musicType, isLiked: isLiked)
    }

    private init(id: String, songName: String, durationSeconds: Int, sortWeight: String?, musicType: Int, isLiked: Bool) {
        self.id = id
        self.songName = songName
        self.durationSeconds = durationSeconds
        self.sortWeight = sortWeight
        self.musicType = musicType
        self.isLiked = isLiked
    }

    private static func string(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> String? {
        if let value = try? c.decode(String.self, forKey: key), !value.isEmpty { return value }
        if let value = try? c.decode(Int64.self, forKey: key) { return String(value) }
        return nil
    }

    private static func int(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Int? {
        if let value = try? c.decode(Int.self, forKey: key) { return value }
        if let value = try? c.decode(String.self, forKey: key) { return Int(value) }
        return nil
    }

    private static func bool(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Bool {
        if let value = try? c.decode(Bool.self, forKey: key) { return value }
        if let value = int(c, key: key) { return value == 1 }
        if let value = try? c.decode(String.self, forKey: key) {
            return value == "1" || value.lowercased() == "true"
        }
        return false
    }
}

struct PartyLocalMusicUpload {
    let songName: String
    let musicURL: String
    let durationSeconds: Int
    let fileFormat: String
}

/// 排麦申请列表 API response（`getQueueSeatList` 的 DTO 包装，spec §2）。
///
/// 字段来源：H5 `apiGetQueueSeatList` response 起草推断；真机 log 未验证前所有字段用兜底
/// (agent-recon-field-names-unverified rule)。手写 `init(from:)` 让缺字段回退到安全默认值，
/// 而非整体 decode 失败（列表接口整体挂 = 房主 Mic Application 面板整体瘫）。
struct PartyMicApplicationListResponse: Decodable, Equatable {
    /// 队列总长度（可能超过 records.count；records 受 pageSize 限制）
    let totalNum: Int
    /// 排麦申请人列表（按排队顺序）
    let records: [PartyMicApplication]
    /// 当前用户在队列中的位序；`-1` 表示不在队列（房主/房管拉时通常 -1）
    let myIndex: Int

    private enum CodingKeys: String, CodingKey {
        case totalNum, records, myIndex
    }

    init(from decoder: Decoder) throws {
        // 后端在队列为空时返 result:null（对齐 decodeArrayOrEmpty 的 "null"→空 兜底语义）
        if let single = try? decoder.singleValueContainer(), single.decodeNil() {
            self.totalNum = 0
            self.records = []
            self.myIndex = -1
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 缺字段兜底：totalNum/records 缺失时视为空列表；myIndex 缺失视为不在队
        self.totalNum = (try? c.decode(Int.self, forKey: .totalNum)) ?? 0
        self.records = (try? c.decode([PartyMicApplication].self, forKey: .records)) ?? []
        self.myIndex = (try? c.decode(Int.self, forKey: .myIndex)) ?? -1
    }
}

// MARK: - Lucky Number DTOs

/// H5 `LuckyNumberConfigResponse` 的宽容解码版本。服务端的数字与开关字段可能混发 String / Int / Bool。
struct PartyLuckyNumberConfig: Decodable, Equatable {
    let roomId: String?
    let numberRangeCode: Int
    let luckyNumber: Int?
    let adminCanSet: Bool
    let canConfigure: Bool

    private enum CodingKeys: String, CodingKey {
        case roomId, numberRangeCode, luckyNumber, adminCanSet, canConfigure
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roomId = Self.string(c, key: .roomId)
        let range = Self.int(c, key: .numberRangeCode) ?? 1
        numberRangeCode = range == 2 || range == 3 ? range : 1
        luckyNumber = Self.int(c, key: .luckyNumber)
        adminCanSet = Self.bool(c, key: .adminCanSet)
        canConfigure = Self.bool(c, key: .canConfigure)
    }

    private static func string(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> String? {
        if let value = try? c.decode(String.self, forKey: key), !value.isEmpty { return value }
        if let value = try? c.decode(Int64.self, forKey: key) { return String(value) }
        return nil
    }

    private static func int(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Int? {
        if let value = try? c.decode(Int.self, forKey: key) { return value }
        if let value = try? c.decode(Int64.self, forKey: key) { return Int(value) }
        if let value = try? c.decode(String.self, forKey: key) { return Int(value) }
        return nil
    }

    private static func bool(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Bool {
        if let value = try? c.decode(Bool.self, forKey: key) { return value }
        if let value = int(c, key: key) { return value == 1 }
        if let value = try? c.decode(String.self, forKey: key) {
            return value == "1" || value.lowercased() == "true"
        }
        return false
    }
}

struct PartyLuckyNumberHistoryResponse: Decodable, Equatable {
    let records: [PartyLuckyNumberHistoryItem]
    let total: Int
    let pageNo: Int

    private enum CodingKeys: String, CodingKey { case records, total, pageNo }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records = (try? c.decode([PartyLuckyNumberHistoryItem].self, forKey: .records)) ?? []
        total = Self.int(c, key: .total) ?? records.count
        pageNo = Self.int(c, key: .pageNo) ?? 1
    }

    private static func int(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Int? {
        if let value = try? c.decode(Int.self, forKey: key) { return value }
        if let value = try? c.decode(Int64.self, forKey: key) { return Int(value) }
        if let value = try? c.decode(String.self, forKey: key) { return Int(value) }
        return nil
    }
}

struct PartyLuckyNumberHistoryItem: Decodable, Equatable, Identifiable {
    let recordId: String
    let nickname: String?
    let avatar: String?
    let luckyNumber: Int

    var id: String { recordId }

    private enum CodingKeys: String, CodingKey {
        case recordId, userId, nickname, avatar, luckyNumber, createTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let userId = Self.string(c, key: .userId) ?? "unknown"
        let number = Self.int(c, key: .luckyNumber) ?? 0
        recordId = Self.string(c, key: .recordId)
            ?? "\(userId)-\(number)-\(Self.string(c, key: .createTime) ?? "")"
        nickname = try? c.decode(String.self, forKey: .nickname)
        avatar = try? c.decode(String.self, forKey: .avatar)
        luckyNumber = number
    }

    private static func string(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> String? {
        if let value = try? c.decode(String.self, forKey: key), !value.isEmpty { return value }
        if let value = try? c.decode(Int64.self, forKey: key) { return String(value) }
        return nil
    }

    private static func int(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Int? {
        if let value = try? c.decode(Int.self, forKey: key) { return value }
        if let value = try? c.decode(Int64.self, forKey: key) { return Int(value) }
        if let value = try? c.decode(String.self, forKey: key) { return Int(value) }
        return nil
    }
}

/// H5 `getQuickPhrases` 单项。接口字段来自 H5 TypeScript 定义；首次真机回包仍应复核字段名。
struct PartyQuickPhrase: Decodable, Equatable, Identifiable {
    let id: String
    let content: String
    let msgType: String?
    let orderNumber: Int

    private enum CodingKeys: String, CodingKey {
        case id, content, msgType, orderNum
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = Self.string(c, key: .id) ?? UUID().uuidString
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        msgType = Self.string(c, key: .msgType)
        orderNumber = Self.int(c, key: .orderNum) ?? 0
    }

    private static func string(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> String? {
        if let value = try? c.decode(String.self, forKey: key), !value.isEmpty { return value }
        if let value = try? c.decode(Int64.self, forKey: key) { return String(value) }
        return nil
    }

    private static func int(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Int? {
        if let value = try? c.decode(Int.self, forKey: key) { return value }
        if let value = try? c.decode(Int64.self, forKey: key) { return Int(value) }
        if let value = try? c.decode(String.self, forKey: key) { return Int(value) }
        return nil
    }
}
