import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "LiveGiftTaskService")

// MARK: - Protocol

/// 直播间礼物任务面板数据源(对齐 H5 `liveGiftTaskTab.vue` + `activeTycoonTaskTab.vue` 消费的 3 接口)。
///
/// **真 API 契约**(严格对齐 H5 store 层字面):
/// - 进度: `POST api/wallet/anchor/taskInfo/liveGiftTask` body `{searchValue: <anchorUserId>}`
///   (H5 store 层 `getLiveGiftTask({searchValue: userId})`;虽 axios 层 `= () => http.post(path, {})`
///   丢参始终发空 body,iOS 严格照 H5 store 层字面传,后端按 token 认无影响)
/// - 送礼历史: `POST /api/live/send/rank/receiveHistoryRankV2` body `{anchorUserId, currentPage, pageSize}`
/// - Tycoon 面板: `POST /api/task/activeTycoon/taskPanel` body `{}`(H5 无入参)
///
/// **method preflight**: 真机验证 POST 空 body 不返 code=1111
/// (对齐 [api-http-method-strict](.claude/rules/api-http-method-strict.md))
protocol LiveGiftTaskServiceProtocol: Sendable {
    func fetchLiveGiftTask(anchorUserId: String) async throws -> GiftTaskProgress
    func fetchLiveGiftHistory(anchorUserId: String, page: Int, pageSize: Int) async throws -> [GiftHistoryItem]
    func fetchActiveTycoonTaskPanel() async throws -> [ActiveTycoonTaskVO]
}

// MARK: - Fakes (支持 5 种 mode 覆盖 spec §5.2 反向)

/// Fakes 实现,支持切换正常 / 空 / 错误 / 超时 / decode 失败 5 种模式。
///
/// 单元测试 & Preview & Step 1b UI 还原时用;Step 2 三轨接线切 Real。
struct LiveGiftTaskServiceFakes: LiveGiftTaskServiceProtocol {
    enum Mode: Sendable {
        case success
        case empty
        /// 每个方法直接 throw
        case error(String)
        /// 模拟慢请求,支持 Task cancel
        case delayed(nanoseconds: UInt64)
        /// 模拟 decode 失败 —— throw DecodingError
        case decodeFail
    }

    let mode: Mode

    init(mode: Mode = .success) {
        self.mode = mode
    }

    func fetchLiveGiftTask(anchorUserId: String) async throws -> GiftTaskProgress {
        try await preflight()
        switch mode {
        case .success:
            return GiftTaskProgress(giftTotal: 1_200, taskAmount: 5_000)
        case .empty:
            return GiftTaskProgress(giftTotal: 0, taskAmount: nil)
        case .error(let msg):
            throw NSError(domain: "LiveGiftTaskFakes", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
        case .delayed, .decodeFail:
            // preflight 已处理
            return GiftTaskProgress(giftTotal: 1_200, taskAmount: 5_000)
        }
    }

    func fetchLiveGiftHistory(anchorUserId: String, page: Int, pageSize: Int) async throws -> [GiftHistoryItem] {
        try await preflight()
        switch mode {
        case .success:
            // 第 1 页 20 条,第 2 页 10 条,第 3 页起为空(触发 finished)
            guard page <= 2 else { return [] }
            let count = page == 1 ? 20 : 10
            let startIdx = (page - 1) * 20
            return (0..<count).map { i in
                let idx = startIdx + i
                return GiftHistoryItem(
                    userId: "user\(idx % 8)",
                    icon: "",
                    nickname: ["Alice", "Bob", "Charlie", "David", "Emma", "Frank", "Grace", "Henry"][idx % 8],
                    headFrame: idx % 3 == 0 ? "https://cdn.example/frame1.png" : nil,
                    activeTycoon: idx % 4 == 0,
                    formattedTime: "\(idx + 1)m ago",
                    giftIcon: "",
                    giftNum: (idx % 5) + 1
                )
            }
        case .empty:
            return []
        case .error(let msg):
            throw NSError(domain: "LiveGiftTaskFakes", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
        case .delayed, .decodeFail:
            return []
        }
    }

    func fetchActiveTycoonTaskPanel() async throws -> [ActiveTycoonTaskVO] {
        try await preflight()
        switch mode {
        case .success:
            // 3 阶段任务:未完成 / 部分完成 / 完成
            let raw: [[String: Any]] = [
                ["taskId": 1, "taskTitle": "Receive 10K diamonds", "taskDesc": "Stage 1 keep going",
                 "targetValue": 10000, "progressValue": 3500, "rewardAmount": 50, "reachFlag": 0,
                 "taskRuleText": "Complete tasks to earn rewards"],
                ["taskId": 2, "taskTitle": "Receive 30K diamonds", "taskDesc": nil as String? as Any,
                 "targetValue": 30000, "progressValue": 30000, "rewardAmount": 200, "reachFlag": 1],
                ["taskId": 3, "taskTitle": "Receive 100K diamonds",
                 "targetValue": 100000, "progressValue": 0, "rewardAmount": 1000, "reachFlag": 0]
            ]
            let data = try JSONSerialization.data(withJSONObject: raw)
            return try JSONDecoder().decode([ActiveTycoonTaskVO].self, from: data)
        case .empty:
            return []
        case .error(let msg):
            throw NSError(domain: "LiveGiftTaskFakes", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
        case .delayed, .decodeFail:
            return []
        }
    }

    /// 处理 delayed / decodeFail 模式(共用预处理)
    private func preflight() async throws {
        switch mode {
        case .delayed(let ns):
            try await Task.sleep(nanoseconds: ns)
        case .decodeFail:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Fakes decodeFail"))
        default:
            return
        }
    }
}

// MARK: - Real (Step 1c 接入真接口)

/// 真 API 实现,走 APIClient。
///
/// **Preflight**(spec §7 #5):POST 空 body 若返 code=1111 "Maybe it's GET"(参
/// [api-http-method-strict](.claude/rules/api-http-method-strict.md) wishlist 案例),
/// Step 3 真机时切换到 `APIClient.shared.get(path)`。
///
/// **wrapper 兼容**:数组类型响应先尝试直接 `[T]` decode,失败再尝试 `{list/data/records: [T]}` 三态
/// wrapper(参 [TaskCenterService.list](../../Work/TaskCenter/TaskCenterService.swift#L34-L57))。
struct LiveGiftTaskServiceReal: LiveGiftTaskServiceProtocol {

    func fetchLiveGiftTask(anchorUserId: String) async throws -> GiftTaskProgress {
        // 严格对齐 H5 store 层字面 `getLiveGiftTask({searchValue: userId})`(live.js:1013)
        // 虽 H5 axios 层 `= () => http.post(path, {})` 丢参始终发空 body,后端按 token 认用户;
        // iOS 传 searchValue 字面对齐,后端等价接受,若未来 H5 axios 层修 bug 不再丢参 iOS 已就绪
        let body: [String: Any] = ["searchValue": anchorUserId]
        let data = try await APIClient.shared.post("/api/wallet/anchor/taskInfo/liveGiftTask", body: body)
        #if DEBUG
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.debug("[Real] fetchLiveGiftTask searchValue=\(anchorUserId, privacy: .private) raw=\(raw, privacy: .private)")
        #endif
        return try JSONDecoder().decode(GiftTaskProgress.self, from: data)
    }

    func fetchLiveGiftHistory(anchorUserId: String, page: Int, pageSize: Int) async throws -> [GiftHistoryItem] {
        let body: [String: Any] = [
            "anchorUserId": anchorUserId,
            "currentPage": page,
            "pageSize": pageSize
        ]
        let data = try await APIClient.shared.post("/api/live/send/rank/receiveHistoryRankV2", body: body)
        #if DEBUG
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.debug("[Real] fetchLiveGiftHistory page=\(page, privacy: .public) raw=\(raw, privacy: .private)")
        #endif
        return decodeArrayFlexible([GiftHistoryItem].self, from: data, wrapperKeys: ["list", "data", "records"])
    }

    func fetchActiveTycoonTaskPanel() async throws -> [ActiveTycoonTaskVO] {
        let data = try await APIClient.shared.post("/api/task/activeTycoon/taskPanel", body: [:])
        #if DEBUG
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.debug("[Real] fetchActiveTycoonTaskPanel raw=\(raw, privacy: .private)")
        #endif
        return decodeArrayFlexible([ActiveTycoonTaskVO].self, from: data, wrapperKeys: ["list", "data", "tasks"])
    }

    /// 数组类型响应三态 wrapper 兼容 —— 先直解 [T],失败尝试 {key: [...]} wrapper 各候选 key
    private func decodeArrayFlexible<T: Decodable>(_ type: [T].Type, from data: Data,
                                                    wrapperKeys: [String]) -> [T] {
        if let arr = try? JSONDecoder().decode([T].self, from: data) {
            return arr
        }
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in wrapperKeys {
                if let raw = dict[key] as? [Any],
                   let d = try? JSONSerialization.data(withJSONObject: raw),
                   let arr = try? JSONDecoder().decode([T].self, from: d) {
                    return arr
                }
            }
        }
        // 无法解析视为空(与 TaskCenterService.list 一致,避免因 decode 全 fail 导致 UI 空态显 error)
        logger.warning("[Real] decodeArrayFlexible: cannot parse response as array or wrapper, returning empty")
        return []
    }
}
