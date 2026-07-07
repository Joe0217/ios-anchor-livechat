import Foundation
import os

/// P2P 会话对端用户画像批查服务（H-1d 用户名/头像补齐）。
///
/// **对齐 H5 `apiBatchQueryYxStat`**（`POST /api/anchor/batchQueryYxStat`）：
/// - Request body: **top-level array** `["uid1", "uid2", ...]`（**非** dict 包装）
/// - Response body: **APIClient 剥完 envelope + 解密后是 dict** `{ "uid1": {nickname, icon, ...}, "uid2": {...} }`
/// - 分批：H5 `onceOnlineStatusCount=100`；对齐同款
/// - 部分批失败仅该批不进结果集，其他批照常返回
///
/// **iOS 落位问题的解**：云信 SDK 的 `NIMSDK.shared().userManager.userInfo(_:)` 只返 SDK **本地缓存**
/// 的 userInfo，新会话对端未登录/未拉过时缓存为空 → nickname 为 nil → session row 显示 sessionId
/// （云信 ID）。H5 靠 apiBatchQueryYxStat 主动拉画像补齐；iOS 同款实现。
@MainActor
final class ConversationProfileService: ConversationProfileProviderProtocol {

    typealias BatchFetcher = (_ ids: [String]) async throws -> [String: ConversationProfile]

    let batchFetcher: BatchFetcher
    let batchSize: Int

    private let logger = Logger(subsystem: "com.anchor.livechat", category: "ConversationProfileService")

    init(batchFetcher: @escaping BatchFetcher, batchSize: Int = 100) {
        self.batchFetcher = batchFetcher
        self.batchSize = batchSize
    }

    static let shared: ConversationProfileService = ConversationProfileService(batchFetcher: { ids in
        let sharedLogger = Logger(subsystem: "com.anchor.livechat", category: "ConversationProfileService")
        sharedLogger.info("🟣 [Profile] request yxAccIds count=\(ids.count, privacy: .public)")
        let data = try await APIClient.shared.post("/api/anchor/batchQueryYxStat", arrayBody: ids)
        sharedLogger.info("🟣 [Profile] raw response bytes=\(data.count, privacy: .public)")
        let dict = try JSONDecoder().decode([String: ConversationProfile].self, from: data)
        sharedLogger.info("🟣 [Profile] decoded profiles count=\(dict.count, privacy: .public)")
        return dict
    })

    /// 分批拉取；空输入短路；单批失败仅该批不进结果集。
    func fetch(yxAccIds: [String]) async -> [String: ConversationProfile] {
        guard !yxAccIds.isEmpty else { return [:] }
        var result: [String: ConversationProfile] = [:]
        for batch in yxAccIds.batched(into: batchSize) {
            do {
                let dict = try await batchFetcher(batch)
                for (k, v) in dict { result[k] = v }
            } catch {
                // view.task / logout / RootView 切换会 cancel 父 Task 级联抛 URLError.cancelled (-999)
                // 参考 LiveStreamViewModel §12-13 已知坑；非真失败，早退避免后续 batch 无谓 warning。
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    logger.info("[Profile] batch cancelled (Task lifecycle) size=\(batch.count, privacy: .public)")
                    return result
                }
                logger.error("[Profile] batch fetch failed size=\(batch.count, privacy: .public) error=\(String(describing: error), privacy: .private)")
            }
        }
        return result
    }
}

/// 依赖注入协议
@MainActor
protocol ConversationProfileProviderProtocol: AnyObject {
    func fetch(yxAccIds: [String]) async -> [String: ConversationProfile]
}

/// H5 `userProfiles[yxAccid]` 结构对齐（v4e 扩展等级/VIP/活跃大 R；对齐 H5 message row 视觉）。
///
/// **兼容**：所有字段都容错（nil），保证 decode 不因单字段缺失整批 fail。
struct ConversationProfile: Decodable, Equatable {
    let nickname: String?
    let icon: String?
    /// 用户段位名（对齐 H5 `userProfiles[uid].userLevelName`，字符串型如 "5" / "50" / "0"；"0" 表示无段位）
    let userLevelName: String?
    /// VIP 过期时间毫秒时间戳；`> Date.now()` 才视为 VIP 有效（H5 `vipExpireTime > Date.now()`）
    let vipExpireTime: Int64?
    /// 活跃大 R 标识（DM-20260429-002；H5 `CActiveTycoonBadge` 显示条件）
    let activeTycoon: Bool?
    /// 在线状态数值（H5 `LIVE_STATUS_NUMBER`；`AnchorOnlineStatus.isOnlineForCall` 判绿点）
    let onlineGroupStatus: Int?

    enum CodingKeys: String, CodingKey {
        case nickname, icon, userLevelName, vipExpireTime, activeTycoon, onlineGroupStatus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.nickname = (try? c.decodeIfPresent(String.self, forKey: .nickname)) ?? nil
        self.icon     = (try? c.decodeIfPresent(String.self, forKey: .icon)) ?? nil
        // userLevelName 后端可能 String/Int 混发，一律收 String
        if let s = try? c.decode(String.self, forKey: .userLevelName), !s.isEmpty {
            self.userLevelName = s
        } else if let i = try? c.decode(Int64.self, forKey: .userLevelName) {
            self.userLevelName = String(i)
        } else {
            self.userLevelName = nil
        }
        self.vipExpireTime = (try? c.decodeIfPresent(Int64.self, forKey: .vipExpireTime)) ?? nil
        self.activeTycoon  = (try? c.decodeIfPresent(Bool.self, forKey: .activeTycoon)) ?? nil
        // onlineGroupStatus 后端可能 Int/String 混发（H5 type.ts 声明 number，实测通用兼容）
        if let i = try? c.decode(Int.self, forKey: .onlineGroupStatus) {
            self.onlineGroupStatus = i
        } else if let s = try? c.decode(String.self, forKey: .onlineGroupStatus), let i = Int(s) {
            self.onlineGroupStatus = i
        } else {
            self.onlineGroupStatus = nil
        }
    }

    /// 便利初始化（测试用）
    init(nickname: String?, icon: String?, userLevelName: String? = nil,
         vipExpireTime: Int64? = nil, activeTycoon: Bool? = nil, onlineGroupStatus: Int? = nil) {
        self.nickname = nickname
        self.icon = icon
        self.userLevelName = userLevelName
        self.vipExpireTime = vipExpireTime
        self.activeTycoon = activeTycoon
        self.onlineGroupStatus = onlineGroupStatus
    }

    /// VIP 是否有效（H5 `vipExpireTime > Date.now()`）
    func isVIPActive(now: Date = Date()) -> Bool {
        guard let expire = vipExpireTime, expire > 0 else { return false }
        return TimeInterval(expire) / 1000.0 > now.timeIntervalSince1970
    }

    /// 是否显示等级 badge（H5 `userLevelName !== '0'`）
    var showsLevelBadge: Bool {
        guard let name = userLevelName, !name.isEmpty, name != "0" else { return false }
        return true
    }

    /// 是否显示 avatar 右下角在线绿点
    var isOnlineForCall: Bool {
        AnchorOnlineStatus.isOnlineForCall(onlineGroupStatus)
    }

    /// 是否已拿到 online 状态数据（用来区分"确认离线"与"状态未知"）
    var hasOnlineStatus: Bool {
        onlineGroupStatus != nil
    }
}
