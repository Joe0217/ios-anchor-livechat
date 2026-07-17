import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "TaskCenterService")

/// Phase C —— 任务中心页 API 封装。对齐 H5 [`api/taskCenter/index.ts`](../../../../Desktop/HN/anchor-livechat-h5/src/api/taskCenter/index.ts) 与
/// `/api/ranking/anchorRanking` 的 method + path 字面
/// (对齐 [api-http-method-strict](.claude/rules/api-http-method-strict.md))。
///
/// 首版**不做 legacy fallback** —— 生产 taskCenter/* 应稳定;失败走 Store.State.error(msg, previous:) + Retry。
protocol TaskCenterServiceProtocol {
    func initTaskCenter() async throws
    func list(cycle: TaskCycle) async throws -> [TaskModuleGroupVO]
    func claim(taskId: Int, tier: Int) async throws -> TaskClaimVO
    func claimAll(taskId: Int) async throws -> TaskClaimAllVO
    func weeklyOverview() async throws -> WeeklyOverviewVO
    func anchorRanking() async throws -> TaskRankInfoVO
    /// H5 并行调用的 V2 —— iOS 不消费返回,仅保留请求以对齐 H5 行为(埋点/流量统计一致)
    func anchorRankingV2() async
}

final class TaskCenterService: TaskCenterServiceProtocol {
    static let shared = TaskCenterService()

    private init() {}

    func initTaskCenter() async throws {
        _ = try await APIClient.shared.post("/api/taskCenter/init", body: [:])
        #if DEBUG
        logger.debug("initTaskCenter OK")
        #endif
    }

    func list(cycle: TaskCycle) async throws -> [TaskModuleGroupVO] {
        let data = try await APIClient.shared.post(
            "/api/taskCenter/list",
            body: ["cycle": cycle.rawValue]
        )
        #if DEBUG
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.debug("list cycle=\(cycle.rawValue, privacy: .public) raw=\(raw, privacy: .private)")
        #endif
        // 首选 array;备选 { list/moduleGroups/data: [] } wrapped(字段名待真机 log 校准)
        if let arr = try? JSONDecoder().decode([TaskModuleGroupVO].self, from: data) {
            return arr
        }
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["list", "moduleGroups", "data"] {
                if let raw = dict[key] as? [Any],
                   let d = try? JSONSerialization.data(withJSONObject: raw),
                   let arr = try? JSONDecoder().decode([TaskModuleGroupVO].self, from: d) {
                    return arr
                }
            }
        }
        logger.error("list cycle=\(cycle.rawValue, privacy: .public) cannot parse response as [ModuleGroup]")
        return []
    }

    func claim(taskId: Int, tier: Int) async throws -> TaskClaimVO {
        let data = try await APIClient.shared.post(
            "/api/taskCenter/claim",
            body: ["taskId": taskId, "tier": tier]
        )
        #if DEBUG
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.debug("claim taskId=\(taskId, privacy: .public) tier=\(tier, privacy: .public) raw=\(raw, privacy: .private)")
        #endif
        return try JSONDecoder().decode(TaskClaimVO.self, from: data)
    }

    func claimAll(taskId: Int) async throws -> TaskClaimAllVO {
        let data = try await APIClient.shared.post(
            "/api/taskCenter/claimAll",
            body: ["taskId": taskId]
        )
        #if DEBUG
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.debug("claimAll taskId=\(taskId, privacy: .public) raw=\(raw, privacy: .private)")
        #endif
        return try JSONDecoder().decode(TaskClaimAllVO.self, from: data)
    }

    func weeklyOverview() async throws -> WeeklyOverviewVO {
        let data = try await APIClient.shared.post(
            "/api/taskCenter/weeklyOverview",
            body: [:]
        )
        #if DEBUG
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.debug("weeklyOverview raw=\(raw, privacy: .private)")
        #endif
        return try JSONDecoder().decode(WeeklyOverviewVO.self, from: data)
    }

    func anchorRanking() async throws -> TaskRankInfoVO {
        let data = try await APIClient.shared.post(
            "/api/ranking/anchorRanking",
            body: [:]
        )
        #if DEBUG
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.debug("anchorRanking raw=\(raw, privacy: .private)")
        #endif
        return try JSONDecoder().decode(TaskRankInfoVO.self, from: data)
    }

    /// H5 index.vue L48-56 `getAnchorRankingV2List` —— 与 V1 并行调用。
    /// V2 返回体仅在 legacy fallback(useTaskCenter=false)时被消费(allDayTask/isLimitTask)。
    /// iOS 决策不做 legacy fallback,但仍**保留调用**与 H5 行为对齐(便于后端流量统计一致)。
    /// 失败静默,返回值 iOS 不消费。
    func anchorRankingV2() async {
        do {
            _ = try await APIClient.shared.post(
                "/api/ranking/anchorRankingV2",
                body: [:]
            )
            #if DEBUG
            logger.debug("anchorRankingV2 OK (returned but not consumed)")
            #endif
        } catch {
            #if DEBUG
            logger.debug("anchorRankingV2 failed (silent): \(String(describing: error), privacy: .private)")
            #endif
        }
    }
}
