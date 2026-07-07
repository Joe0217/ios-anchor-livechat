import Foundation
import os

/// Prime 等级批量拉取（H-1 MVP，spec §1.3 + §3.2 R-2）。
///
/// **分批策略**（对齐 H5 `session.js:583-625`）：
/// - 每批 ≤ `batchSize` 个 uid（默认 50）
/// - 任一批失败仅该批不进结果集，其他批**照常返回**（不整批降级）
/// - 全部批失败 → 返回空 Set（Store 层 R-1 处理 fallback：Prime tab 空，Flame/Stranger 不受影响）
///
/// **依赖注入**：`batchFetcher` 闭包让 HilyTests 可注入 mock 覆盖分批 + 部分失败反向；
/// `PrimeLevelService.shared` 用真 APIClient 实现。
@MainActor
final class PrimeLevelService: PrimeLevelProviderProtocol {

    typealias BatchFetcher = (_ ids: [String]) async throws -> [String]

    let batchFetcher: BatchFetcher
    let batchSize: Int

    private let logger = Logger(subsystem: "com.anchor.livechat", category: "PrimeLevelService")

    init(batchFetcher: @escaping BatchFetcher, batchSize: Int = 50) {
        self.batchFetcher = batchFetcher
        self.batchSize = batchSize
    }

    /// 真实生产实例：调 `/api/anchor/messageLevelLimit`。
    static let shared: PrimeLevelService = PrimeLevelService(batchFetcher: { ids in
        let sharedLogger = Logger(subsystem: "com.anchor.livechat", category: "PrimeLevelService")
        sharedLogger.info("🟣 [Prime] request yxAccId count=\(ids.count, privacy: .public)")
        let body: [String: Any] = ["yxAccId": ids]
        let data = try await APIClient.shared.post("/api/anchor/messageLevelLimit", body: body)
        sharedLogger.info("🟣 [Prime] raw response bytes=\(data.count, privacy: .public) preview=\(String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>", privacy: .private)")
        let resp = try JSONDecoder().decode(PrimeLevelResponse.self, from: data)
        sharedLogger.info("🟣 [Prime] decoded result count=\(resp.result.count, privacy: .public)")
        return resp.result
    })

    func fetchPrime(yxAccIds: [String]) async -> Set<String> {
        guard !yxAccIds.isEmpty else { return [] }

        var result: Set<String> = []
        for batch in yxAccIds.batched(into: batchSize) {
            do {
                let uids = try await batchFetcher(batch)
                result.formUnion(uids)
            } catch {
                // view.task / logout / RootView 切换会 cancel 父 Task 级联抛 URLError.cancelled (-999)
                // 参考 LiveStreamViewModel §12-13 已知坑；非真失败，早退避免后续 batch 无谓 warning。
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    logger.info("[PrimeLevel] batch cancelled (Task lifecycle) size=\(batch.count, privacy: .public)")
                    return result
                }
                logger.error("[PrimeLevel] batch fetch failed size=\(batch.count, privacy: .public) error=\(String(describing: error), privacy: .private)")
            }
        }
        return result
    }
}

// MARK: - Array 分批 helper

extension Array {
    /// 按 size 分批（最后一批可能不足 size）
    func batched(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
