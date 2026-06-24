import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "PKService")

/// G 里程碑 spec §4：PK 接口层。
///
/// 全部走 `APIClient.shared.post` AES 加解密 + 公共头链路（与 B/C/D 一致）。
/// 错误码 1004/1005 在 APIClient 单点分流 logout，PKService 仅转译 APIError → PKServiceError.business。
///
/// **必用 11 个**（spec §1.4）：startPkMatch / cancelMatch / joinPk / invitePk / handleInvite /
/// endPk / endPunishing / getPkTop3RankList / getPkStatus / mutePkRoom / updateInviteSwitch。
/// **占位 6 个**（throw `.notImplemented`，待 H/I 接续）：getPkRankList / getRecommendAnchorList /
/// getPkRecordList / queryInviteSwitch / getPkInfo / selectPKRuleIcon。
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

    // MARK: - 6 占位接口（G 范围外，throw notImplemented）

    /// 占位：PK 全榜（H 礼物全景阶段可能接入）。
    static func getPkRankList(pkId: String, anchorId: Int) async throws -> [PKTopUser] {
        throw PKServiceError.notImplemented
    }

    /// 占位：邀请列表/搜索推荐主播（G 极简版仅"输入对手 ID"，不做推荐列表）。
    static func getRecommendAnchorList(pageSize: Int, anchorId: String?, nickname: String?) async throws -> [PKTopUser] {
        throw PKServiceError.notImplemented
    }

    /// 占位：PK 历史记录（G 范围外）。
    static func getPkRecordList(currentPage: Int?, pageSize: Int?) async throws -> [PKTopUser] {
        throw PKServiceError.notImplemented
    }

    /// 占位：查询接受邀请开关（H5 用，G 由 enter inPK 时直接覆盖 + 快照恢复，不主动查询）。
    static func queryInviteSwitch() async throws -> Int {
        throw PKServiceError.notImplemented
    }

    /// 占位：客态 PK 进房拉双主播信息（G 客态范围外）。
    static func getPkInfo(anchorId: Int) async throws -> Data {
        throw PKServiceError.notImplemented
    }

    /// 占位：PK 规则图（G 不做规则 UI）。注意接口在 `/api/agora/live/selectPKRuleIcon`（非 /api/pk）。
    static func selectPKRuleIcon() async throws -> String {
        throw PKServiceError.notImplemented
    }
}
