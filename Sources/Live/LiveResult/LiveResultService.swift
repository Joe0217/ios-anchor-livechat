import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "LiveResultService")

/// 直播结果页数据层。对齐 H5 `api/live/index.ts:63 queryLiveStat`。
///
/// **body 字段**：`beginTimestamp` / `endTimestamp` 毫秒 Int64（对齐 H5 liveStore.liveTime）。
/// **解码策略**：手解 dict（Codable 应对不了 userId Number/String / followFlag Int/Bool 双兼容），
/// 复用 UserProfileService 的 NSNumber objCType 分辨技巧。
enum LiveResultService {
    /// 拉取直播统计数据。
    /// - Parameters:
    ///   - begin: 毫秒时间戳
    ///   - end: 毫秒时间戳
    static func queryLiveStat(begin: Int64, end: Int64) async throws -> LiveStatData {
        let body: [String: Any] = ["beginTimestamp": begin, "endTimestamp": end]
        let data = try await APIClient.shared.post("/api/agora/live/queryLiveStat", body: body)
        guard let stat = parse(from: data) else {
            throw APIError(code: "decode", message: "Failed to decode live stat")
        }
        logger.info("queryLiveStat ok view=\(stat.viewNum) gifters=\(stat.giftRanks.count) calls=\(stat.privateCalls.count)")
        return stat
    }

    // MARK: - Decode

    /// 解 envelope `result` 为 `LiveStatData`。
    /// envelope 已由 APIClient 剥壳，此处只处理 `result` 内层字典。
    static func parse(from data: Data) -> LiveStatData? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            let preview = String(data: data.prefix(120), encoding: .utf8) ?? "<binary>"
            logger.error("parse: cannot parse, preview=\(preview, privacy: .private)")
            return nil
        }

        let viewNum = intValue(dict["viewNum"]) ?? 0
        let followNum = intValue(dict["followNum"]) ?? 0
        let incomeDiamonds = intValue(dict["incomeDiamonds"]) ?? 0

        let giftRanks: [GiftRankItem] = (dict["giftRanks"] as? [[String: Any]] ?? [])
            .compactMap(parseGiftRankItem(from:))
        let privateCalls: [PrivateCallItem] = (dict["privateCalls"] as? [[String: Any]] ?? [])
            .compactMap(parsePrivateCallItem(from:))

        return LiveStatData(
            viewNum: viewNum,
            followNum: followNum,
            incomeDiamonds: incomeDiamonds,
            giftRanks: giftRanks,
            privateCalls: privateCalls
        )
    }

    static func parseGiftRankItem(from dict: [String: Any]) -> GiftRankItem? {
        guard let userId = stringId(dict["userId"]) else { return nil }
        // 头像 URL 字段名兼容：H5 用 `icon`，其它接口可能返 `avatar` / `iconUrl` / `headImg` / `photo`
        let avatarURL = firstNonEmptyString(dict, keys: ["icon", "avatar", "iconUrl", "headImg", "photo", "avatarUrl"])
        // 昵称字段名兼容：H5 用 `nickname`，其它接口可能返 `nickName` / `name`
        let name = firstNonEmptyString(dict, keys: ["nickname", "nickName", "name"])
        // 钻石数字段名兼容：consumeDiamonds（H5 模板）/ diamonds / giftValue / totalDiamonds / amount
        let diamonds = intValue(dict["consumeDiamonds"])
                    ?? intValue(dict["diamonds"])
                    ?? intValue(dict["giftValue"])
                    ?? intValue(dict["totalDiamonds"])
                    ?? intValue(dict["amount"])
                    ?? 0
        // DEBUG 期真机排查：若 icon/nickname/diamonds 都 miss 时打全 keys
        #if DEBUG
        if avatarURL == nil || name == nil {
            let keys = dict.keys.sorted().joined(separator: ",")
            logger.warning("giftRank icon/nickname fields miss; dict keys=\(keys, privacy: .public)")
        }
        #endif
        return GiftRankItem(
            userId: userId,
            icon: avatarURL,
            nickname: name,
            consumeDiamonds: diamonds,
            followed: boolFlag(dict["followFlag"]),
            yxAccid: dict["yxAccid"] as? String
        )
    }

    static func parsePrivateCallItem(from dict: [String: Any]) -> PrivateCallItem? {
        guard let userId = stringId(dict["userId"]) else { return nil }
        let avatarURL = firstNonEmptyString(dict, keys: ["icon", "avatar", "iconUrl", "headImg", "photo", "avatarUrl"])
        let name = firstNonEmptyString(dict, keys: ["nickname", "nickName", "name"])
        // 通话时长字段兼容：`callDuration` / `duration` / `callTime` / `talkTime`
        let duration = intValue(dict["callDuration"])
                    ?? intValue(dict["duration"])
                    ?? intValue(dict["callTime"])
                    ?? intValue(dict["talkTime"])
                    ?? 0
        return PrivateCallItem(
            userId: userId,
            icon: avatarURL,
            nickname: name,
            callDurationSeconds: duration,
            followed: boolFlag(dict["followFlag"]),
            yxAccid: dict["yxAccid"] as? String
        )
    }

    /// 取 keys 里第一个非空 String 值
    static func firstNonEmptyString(_ dict: [String: Any], keys: [String]) -> String? {
        for k in keys {
            if let s = dict[k] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    // MARK: - Helpers（对齐 UserProfileService.parseDetail 模式）

    /// userId String/Int 双兼容（.claude/rules/ios-decode-userid-compat.md）。
    static func stringId(_ raw: Any?) -> String? {
        if let s = raw as? String, !s.isEmpty { return s }
        if let n = raw as? NSNumber {
            let cType = String(cString: n.objCType)
            if cType != "c" && cType != "B" { return n.stringValue }
        }
        return nil
    }

    static func intValue(_ raw: Any?) -> Int? {
        if let n = raw as? Int { return n }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    /// followFlag Int/Bool 双兼容。
    /// - Bool true → true
    /// - Int 1 → true；Int 0 → false
    /// - 其它 → false（未关注）
    static func boolFlag(_ raw: Any?) -> Bool {
        guard let n = raw as? NSNumber else {
            if let s = raw as? String { return s == "1" || s.lowercased() == "true" }
            return false
        }
        let cType = String(cString: n.objCType)
        if cType == "c" || cType == "B" { return n.boolValue }
        return n.intValue == 1
    }
}
