import Foundation

/// H-3 回复积分服务协议（spec §3.1）。
///
/// **依赖注入**：`ReplyPointsStore.shared` 用真实 `ReplyPointsHTTPService`；
/// 单测传 `FakeReplyPointsService`（对齐 `FakeP2PChatProvider` / `FakeEditProfileService` 模式）。
protocol ReplyPointsServiceProtocol: Sendable {
    /// `/api/im/getMessagePoint`
    ///
    /// **失败语义**：抛错代表接口异常；**null / 空 result** 应由实现层归一化成"未开付费"—— 由调用方（Store）
    /// 判 `!res.pointInfoList.isEmpty` 决定 `isOpenPaidMessage`（H-3 spec §1.2.1）。
    func fetchMessageBoxList(userYxAccid: String) async throws -> MessageBoxList

    /// `/api/im/treasurePointBox` → 返回本次领取的钻石数
    func claimTreasureBox(userYxAccid: String) async throws -> Int

    /// `/api/im/settleReplyPoints`
    ///
    /// **msgType**（v3 §S2 spike 待抓包；先按 msg.type raw string 传：`text`/`image`/`video`/`audio`）
    func settleReplyPoints(userYxAccid: String, userMsgId: String, msgType: String) async throws -> SettleReplyPointsResult

    /// `/api/im/getMessagePointRecord`（Batch 6.1.2；对齐 H5 `apiGetAnchorMessageBoxRecord`）→ 奖励记录列表
    func fetchMessageBoxRecords(userYxAccid: String) async throws -> [MessageBoxRecordItem]
}

/// 奖励记录单条（Batch 6.1.2；对齐 H5 `rewardRecordsPop.vue:71-83` 字段 `point / diamond / createTime`）。
struct MessageBoxRecordItem: Decodable, Equatable, Hashable, Identifiable {
    let id: String
    let point: Int
    let diamond: Int
    /// 毫秒时间戳（H5 用 dayjs 格式化 `YYYY-MM-DD`）
    let createTime: Int64

    enum CodingKeys: String, CodingKey {
        case id, point, diamond, createTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // id: String/Int 双兼容（ios-decode-userid-compat 规则）
        if let s = try? c.decode(String.self, forKey: .id) {
            self.id = s
        } else if let i = try? c.decode(Int64.self, forKey: .id) {
            self.id = String(i)
        } else {
            self.id = UUID().uuidString
        }
        self.point   = (try? c.decodeIfPresent(Int.self, forKey: .point)) ?? 0
        self.diamond = (try? c.decodeIfPresent(Int.self, forKey: .diamond)) ?? 0
        self.createTime = (try? c.decodeIfPresent(Int64.self, forKey: .createTime)) ?? 0
    }

    /// 便利初始化（供 Fake / Preview）
    init(id: String, point: Int, diamond: Int, createTime: Int64) {
        self.id = id
        self.point = point
        self.diamond = diamond
        self.createTime = createTime
    }
}

/// 真实网络实现（依赖 APIClient）。Step 1c 完成字段抓包后可能微调 Codable。
///
/// 用 struct 而非 enum：protocol 要求 instance methods，enum static 方法不满足；
/// 单例 `.shared` 用作 `ReplyPointsStore.shared` 的默认依赖注入。
struct ReplyPointsHTTPService: ReplyPointsServiceProtocol, Sendable {
    static let shared = ReplyPointsHTTPService()

    func fetchMessageBoxList(userYxAccid: String) async throws -> MessageBoxList {
        let data = try await APIClient.shared.post(
            "/api/im/getMessagePoint",
            body: ["userYxAccid": userYxAccid]
        )
        return try JSONDecoder().decode(MessageBoxList.self, from: data)
    }

    func claimTreasureBox(userYxAccid: String) async throws -> Int {
        let data = try await APIClient.shared.post(
            "/api/im/treasurePointBox",
            body: ["userYxAccid": userYxAccid]
        )
        struct DiamondResp: Decodable { let diamond: Int }
        return try JSONDecoder().decode(DiamondResp.self, from: data).diamond
    }

    func settleReplyPoints(userYxAccid: String, userMsgId: String, msgType: String) async throws -> SettleReplyPointsResult {
        let data = try await APIClient.shared.post(
            "/api/im/settleReplyPoints",
            body: ["userYxAccid": userYxAccid, "userMsgId": userMsgId, "msgType": msgType]
        )
        return try JSONDecoder().decode(SettleReplyPointsResult.self, from: data)
    }

    func fetchMessageBoxRecords(userYxAccid: String) async throws -> [MessageBoxRecordItem] {
        let data = try await APIClient.shared.post(
            "/api/im/getMessagePointRecord",
            body: ["userYxAccid": userYxAccid]
        )
        return try JSONDecoder().decode([MessageBoxRecordItem].self, from: data)
    }
}
