import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "PKService")

/// G 里程碑 spec §4：PK 接口层。
///
/// 全部走 `APIClient.shared.post` AES 加解密 + 公共头链路（与 B/C/D 一致）。
/// 错误码 1004/1005 在 APIClient 单点分流 logout，PKService 仅转译 APIError → PKServiceError.business。
///
/// **必用 14 个**（spec §1.4 + 2026-06-25 §1.2 反悔扩展 + 2026-07-10 PK 贡献榜 sheet 接入）：
/// startPkMatch / cancelMatch / joinPk / invitePk / handleInvite / endPk / endPunishing /
/// getPkTop3RankList / getPkStatus / mutePkRoom / updateInviteSwitch /
/// **getRecommendAnchorList / queryInviteSwitch / getPkRankList**（贡献榜 sheet）。
/// **后续范围外**：selectPKRuleIcon 以外不再保留客态 PK 占位；`getPkInfo` 已由客态观看页接入。
enum PKService {
    // MARK: - 通用响应解码 helper

    /// 大部分 PK 接口仅 0000 / 业务码，无 result 数据；调用方拿到 Void 即可。
    private static func postNoResult(_ path: String, body: [String: Any]) async throws {
        do {
            _ = try await APIClient.shared.post(path, body: body)
        } catch let err as APIError {
            throw PKServiceError.business(code: err.code, message: err.message)
        }
    }

    /// 走 Codable decode 的 PK 接口公用入口。
    private static func postDecode<T: Decodable>(_ path: String,
                                                  body: [String: Any],
                                                  _ type: T.Type) async throws -> T {
        let data: Data
        do {
            data = try await APIClient.shared.post(path, body: body)
        } catch let err as APIError {
            throw PKServiceError.business(code: err.code, message: err.message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            logger.error("decode \(path, privacy: .public) failed: \(String(describing: error), privacy: .private)")
            throw PKServiceError.decode(error)
        }
    }

    // MARK: - 11 必用接口

    /// 发起随机匹配。`isMatchRetry=false` 表示 QUICK 15s 阶段，`true` 表示 RETRY 5min。
    /// **真机验证**：后端响应 `result: null`——含义"已进匹配池，等 NIM 推送"；不返回对手信息。
    /// 对手信息走 NIM attachType=100 pkStatus=10（`PKStatusBundle`）推送，不在本接口响应。
    /// （原假设返回 PKMatchResult 是早期 Explore 推断错误，2026-06-24 真机日志实证 result:null）
    static func startPkMatch(isMatchRetry: Bool) async throws {
        try await postNoResult("/api/pk/startPkMatch", body: ["isMatchRetry": isMatchRetry])
    }

    /// 取消随机匹配。
    static func cancelMatch() async throws {
        try await postNoResult("/api/pk/cancelMatch", body: [:])
    }

    /// 加入 PK（匹配成功后 / 邀请被接受后），后端返回 pkId 与对手 yxAccId / endTime。
    static func joinPk(roomId: Int,
                       pkDuration: Int,
                       oppositeAnchorId: Int,
                       pkType: PKType) async throws -> PKJoinResponse {
        let body: [String: Any] = [
            "roomId": roomId,
            "pkDuration": pkDuration,
            "oppositeAnchorId": oppositeAnchorId,
            "pkType": pkType.rawValue,
        ]
        return try await postDecode("/api/pk/joinPk", body: body, PKJoinResponse.self)
    }

    /// 邀请指定主播 PK。H5 用 `autoShowErrorToast=false`，iOS 由调用方 catch 决定 UI。
    static func invitePk(anchorId: Int, pkDuration: Int) async throws {
        try await postNoResult("/api/pk/invitePk",
                               body: ["anchorId": anchorId, "pkDuration": pkDuration])
    }

    /// 处理邀请（接受/拒绝/超时/取消）。
    /// - `inviterId`：accept/reject 时为邀请者 ID；timeout/cancel 时为被邀请者 ID
    /// - `pkDuration`：邀请时序的 PK 时长（秒）；H5 `handleInviteApi` 入参一致
    static func handleInvite(inviterId: Int,
                             type: PKInviteHandle,
                             pkDuration: Int) async throws {
        let body: [String: Any] = [
            "inviterId": inviterId,
            "type": type.rawValue,
            "pkDuration": pkDuration,
        ]
        try await postNoResult("/api/pk/handleInvite", body: body)
    }

    /// PK 进行中主动中断 / 倒计时自然结束。
    static func endPk(pkId: String,
                      roomId: Int,
                      oppositeAnchorId: Int,
                      isActiveDisconnect: PKDisconnectType) async throws {
        let body: [String: Any] = [
            "pkId": pkId,
            "roomId": roomId,
            "oppositeAnchorId": oppositeAnchorId,
            "isActiveDisconnect": isActiveDisconnect.rawValue,
        ]
        try await postNoResult("/api/pk/endPk", body: body)
    }

    /// 结束惩罚阶段（120s 自然到 / 主动断开）。
    static func endPunishing(pkId: String,
                             roomId: Int,
                             oppositeAnchorId: Int,
                             isActiveDisconnect: PKDisconnectType,
                             disconnectFromStatus: PKPunishFromStatus) async throws {
        let body: [String: Any] = [
            "pkId": pkId,
            "roomId": roomId,
            "oppositeAnchorId": oppositeAnchorId,
            "isActiveDisconnect": isActiveDisconnect.rawValue,
            "disconnectFromStatus": disconnectFromStatus.rawValue,
        ]
        try await postNoResult("/api/pk/endPunishing", body: body)
    }

    /// PK 结束时拉贡献榜 Top3（spec §1.4 PKTop3User 数组）。
    static func getPkTop3RankList(pkId: String, anchorId: Int) async throws -> [PKTopUser] {
        let body: [String: Any] = ["pkId": pkId, "anchorId": anchorId]
        return try await postDecode("/api/pk/getPkTop3RankList", body: body, [PKTopUser].self)
    }

    /// 中断重连同步 PK 状态（'INPK' / 'PUNISHING' / null）。
    /// APIClient 在 result 为 null 时返回 `Data("null".utf8)`，JSONDecoder 解 String 会失败 → 抛 decode。
    /// 调用方 catch decode 视为 nil（不在 PK 中）。
    static func getPkStatus() async throws -> PKRemoteStatus? {
        let data: Data
        do {
            data = try await APIClient.shared.post("/api/pk/getPkStatus", body: [:])
        } catch let err as APIError {
            throw PKServiceError.business(code: err.code, message: err.message)
        }
        // 优先解原字符串（APIClient 返回 Data("INPK".utf8) 之类未带引号的可能性需保护）
        if let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) {
            if s.isEmpty || s == "null" { return nil }
            return PKRemoteStatus(rawValue: s)
        }
        return nil
    }

    /// 静音对方主播（mute=1 / 0）。同时由调用方发 attachType=-8 NIM 广播观众端同步。
    static func mutePkRoom(mute: Bool) async throws {
        try await postNoResult("/api/pk/mutePkRoom", body: ["mute": mute ? 1 : 0])
    }

    /// 切换"接受邀请"开关。`searchValue=1` 关闭 / `0` 开启（H5 字段语义反直觉，sopec §B 已警示）。
    /// PK enter inPK 时 PKStore 调本接口关闭；exit endingPK 时按快照恢复。
    static func updateInviteSwitch(close: Bool) async throws {
        try await postNoResult("/api/pk/updateInviteSwitch",
                               body: ["searchValue": close ? 1 : 0])
    }

    // MARK: - PK 贡献榜（H5 pkRankListPopup.vue 接口）

    /// PK 贡献榜（`POST /api/pk/getPkRankList` body `{pkId, anchorId}`）。
    ///
    /// H5 蓝本：`anchor-livechat-h5/src/api/livePk/index.ts` L81-83；
    /// `anchor-livechat-h5/src/views/liveRoom/components/pkLive/pkRankListPopup.vue` L45-73。
    /// H5 响应 `res || []`——直接是数组；APIClient 已剥 `result` 层，data 就是 `[PKRankItem]` json。
    /// 兼容后端可能返回 `{list/records/data: [...]}` 包装（参 getRecommendAnchorList 兜底模式）。
    static func getPkRankList(pkId: String, anchorId: Int) async throws -> [PKRankItem] {
        let body: [String: Any] = ["pkId": pkId, "anchorId": anchorId]
        let data: Data
        do {
            data = try await APIClient.shared.post("/api/pk/getPkRankList", body: body)
        } catch let err as APIError {
            throw PKServiceError.business(code: err.code, message: err.message)
        }
        // 裸数组优先（H5 响应形态）
        if let arr = try? JSONDecoder().decode([PKRankItem].self, from: data) {
            return arr
        }
        // 包装结构兜底
        struct Wrapper: Decodable {
            let list: [PKRankItem]?
            let records: [PKRankItem]?
            let data: [PKRankItem]?
        }
        if let wrap = try? JSONDecoder().decode(Wrapper.self, from: data) {
            return wrap.list ?? wrap.records ?? wrap.data ?? []
        }
        logger.error("decode /api/pk/getPkRankList failed; raw=\(String(data: data, encoding: .utf8) ?? "nil", privacy: .private)")
        throw PKServiceError.decode(NSError(domain: "PKService", code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: "getPkRankList decode failed"]))
    }

    // MARK: - 3 占位接口（G 范围外，throw notImplemented）

    /// 推荐主播列表 / 搜索（spec §1.2 反悔扩展，2026-06-25 G #11 落地）。
    ///
    /// H5 蓝本：`useServerPagination(getRecommendAnchorsApi, {pageSize: 20})` + `buildSearchParams`。
    /// - 不传 `anchorId` / `nickname` → 推荐列表
    /// - 纯数字搜索 → 走 `anchorId: Int`
    /// - 非数字搜索 → 走 `nickname: String`
    /// - 分页：`currentPage` 从 1 开始；`pageSize` 默认 20
    ///
    /// 后端响应可能是 `{list/records/data: [...]}` 包装或裸数组——`PKRecommendListPagedResponse` decode 失败时
    /// 直接尝试解为 `[PKRecommendAnchor]` 兜底。
    static func getRecommendAnchorList(currentPage: Int = 1,
                                       pageSize: Int = 20,
                                       anchorId: Int? = nil,
                                       nickname: String? = nil) async throws -> [PKRecommendAnchor] {
        var body: [String: Any] = ["currentPage": currentPage, "pageSize": pageSize]
        if let anchorId { body["anchorId"] = anchorId }
        if let nickname, !nickname.isEmpty { body["nickname"] = nickname }
        let data: Data
        do {
            data = try await APIClient.shared.post("/api/pk/getRecommendAnchorList", body: body)
        } catch let err as APIError {
            throw PKServiceError.business(code: err.code, message: err.message)
        }
        // 包装结构优先
        if let wrap = try? JSONDecoder().decode(PKRecommendListPagedResponse.self, from: data) {
            return wrap.items
        }
        // 裸数组兜底
        if let arr = try? JSONDecoder().decode([PKRecommendAnchor].self, from: data) {
            return arr
        }
        logger.error("decode /api/pk/getRecommendAnchorList failed; raw=\(String(data: data, encoding: .utf8) ?? "nil", privacy: .private)")
        throw PKServiceError.decode(NSError(domain: "PKService", code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: "getRecommendAnchorList decode failed"]))
    }

    /// PK 历史记录分页（`POST /api/pk/getPkRecordList` body `{currentPage, pageSize}`）。
    ///
    /// H5 蓝本：`anchor-livechat-h5/src/api/livePk/index.ts:113` getPkHistoryApi +
    /// `pkHistoryPopup.vue` useServerPagination dataPath='records'。
    /// **响应**：`{records: [...], validWinCount, totalPkCount, hasMore?}` — 首页含统计元数据
    static func getPkRecordList(currentPage: Int = 1, pageSize: Int = 20) async throws -> PKRecordPage {
        let body: [String: Any] = ["currentPage": currentPage, "pageSize": pageSize]
        let data: Data
        do {
            data = try await APIClient.shared.post("/api/pk/getPkRecordList", body: body)
        } catch let err as APIError {
            throw PKServiceError.business(code: err.code, message: err.message)
        }
        // 2026-07-13 修：后端 `result: null` 语义 = 无数据（对齐 H5 `res || []`）。APIClient 剥 envelope
        // 后 data 是字面 "null"（4 字节）→ decode keyed container throw valueNotFound。判 null 兜底空 page
        // 避免 store loadMoreIfNeeded 死循环（catch 后 hasMore 仍 true → sentinel 反复触发）
        if let jsonAny = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]),
           jsonAny is NSNull {
            return PKRecordPage.emptyNoMore
        }
        do {
            return try JSONDecoder().decode(PKRecordPage.self, from: data)
        } catch {
            logger.error("decode /api/pk/getPkRecordList failed: \(String(describing: error), privacy: .private)")
            throw PKServiceError.decode(error)
        }
    }

    /// 查询接受邀请开关状态（2026-06-25 G #11 落地：邀请弹窗 UI 接入）。
    ///
    /// 后端返回语义不固定（可能 Bool / Int 0|1 / String "0"|"1"），全兼容；
    /// **统一返回 `acceptEnabled: Bool`**（true=接受开启，false=关闭）。
    /// - H5 `acceptInvitation.value = res` 同语义：接受开关本身
    /// - 与 `updateInviteSwitch(close:)` 反向：close=true 即 acceptEnabled=false
    static func queryInviteSwitch() async throws -> Bool {
        let data: Data
        do {
            data = try await APIClient.shared.post("/api/pk/queryInviteSwitch", body: [:])
        } catch let err as APIError {
            throw PKServiceError.business(code: err.code, message: err.message)
        }
        // 优先解 Bool
        if let b = try? JSONDecoder().decode(Bool.self, from: data) { return b }
        // 解 Int（0=关闭接受 / 1=开启 — 与 searchValue 反向；H5 后端 H5 res 直 unwrap 用 truthy）
        if let i = try? JSONDecoder().decode(Int.self, from: data) { return i != 0 }
        // 解 String "true"/"1" → true
        if let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) {
            if s.isEmpty || s == "null" { return true }            // 缺省视为开启接受
            if s == "true" || s == "1" { return true }
            if s == "false" || s == "0" { return false }
        }
        logger.warning("queryInviteSwitch unknown response; default to true (accept enabled)")
        return true
    }

    /// 客态 PK 进房拉双方主播、比分、频道和阶段信息。
    ///
    /// 对齐 H5 `getPkInfoApi({ anchorId })`。保留原始 Data 由客态的宽松解析器读取，
    /// 因后端 `pkDuration` / top3 / avatar 等字段存在 Number/String/对象数组混发。
    static func getPkInfo(anchorId: Int) async throws -> Data {
        do {
            return try await APIClient.shared.post("/api/pk/getPkInfo", body: ["anchorId": anchorId])
        } catch let err as APIError {
            throw PKServiceError.business(code: err.code, message: err.message)
        }
    }

    /// PK 规则图片 URL（`POST /api/agora/live/selectPKRuleIcon`）。
    ///
    /// H5 蓝本：`anchor-livechat-h5/src/api/livePk/index.ts:148` `getPkRuleImgApi` →
    /// `pkRulePopup.vue:17-24` `res.liveIcon` 作为规则图片 src。
    ///
    /// 接口路径**在 `/api/agora/live/*`，非 `/api/pk/*`**（与其他 PK 接口分域，参 [api-http-method-strict]）。
    /// 返回图片 URL；空/失败由调用方决定 fallback（PKRulePopup 显示空态）。
    static func selectPKRuleIcon() async throws -> String {
        let data: Data
        do {
            data = try await APIClient.shared.post("/api/agora/live/selectPKRuleIcon", body: [:])
        } catch let err as APIError {
            throw PKServiceError.business(code: err.code, message: err.message)
        }
        struct Resp: Decodable { let liveIcon: String? }
        if let resp = try? JSONDecoder().decode(Resp.self, from: data) {
            return resp.liveIcon ?? ""
        }
        // 兼容裸字符串（后端可能直接返 String）
        if let s = try? JSONDecoder().decode(String.self, from: data) {
            return s
        }
        logger.error("decode /api/agora/live/selectPKRuleIcon failed; raw=\(String(data: data, encoding: .utf8) ?? "nil", privacy: .private)")
        return ""
    }
}
