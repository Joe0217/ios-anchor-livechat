import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "PointsRankService")

/// Phase E —— 积分排行榜 API 封装。对齐 H5 [`api/pointsRank/index.ts`](../../../../Desktop/HN/anchor-livechat-h5/src/api/pointsRank/index.ts)。
///
/// 唯一接口:`POST /api/ranking/anchorIntegralRankingList` `{searchValue: 'week'}`
/// —— H5 硬编码 week,iOS 完全对齐,无 monthly/allTime。
protocol PointsRankServiceProtocol {
    func fetchWeeklyRank() async throws -> PointsRankListResponse
}

final class PointsRankService: PointsRankServiceProtocol {
    static let shared = PointsRankService()

    private init() {}

    func fetchWeeklyRank() async throws -> PointsRankListResponse {
        let data = try await APIClient.shared.post(
            "/api/ranking/anchorIntegralRankingList",
            body: ["searchValue": "week"]
        )
        #if DEBUG
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.debug("fetchWeeklyRank raw=\(raw, privacy: .private)")
        #endif
        return try JSONDecoder().decode(PointsRankListResponse.self, from: data)
    }
}
