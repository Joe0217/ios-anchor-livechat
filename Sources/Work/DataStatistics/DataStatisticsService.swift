import Foundation

protocol DataStatisticsServiceProtocol {
    func fetchDashboard() async throws -> DataStatisticsDashboard
    func fetchDeductionCondition() async throws -> DataStatisticsDeductionCondition
    func submitDeduction() async throws
}

final class DataStatisticsService: DataStatisticsServiceProtocol {
    static let shared = DataStatisticsService()

    private init() {}

    func fetchDashboard() async throws -> DataStatisticsDashboard {
        async let previewData = APIClient.shared.post("/api/chat/dataPreview", body: [:])
        async let levelData = APIClient.shared.post("/api/anchor/anchorAutoLevelUpInfo", body: [:])
        async let benefitsData = APIClient.shared.post("/api/chat/getLevelConfig", body: [:])
        let (preview, level, benefits) = try await (previewData, levelData, benefitsData)
        let decoder = JSONDecoder()
        return try DataStatisticsDashboard(
            preview: decoder.decode(DataStatisticsPreview.self, from: preview),
            levelInfo: decoder.decode(DataStatisticsLevelInfo.self, from: level),
            benefits: decoder.decode(DataStatisticsBenefits.self, from: benefits)
        )
    }

    func fetchDeductionCondition() async throws -> DataStatisticsDeductionCondition {
        let data = try await APIClient.shared.post("/api/chat/checkCondition", body: [:])
        return try JSONDecoder().decode(DataStatisticsDeductionCondition.self, from: data)
    }

    func submitDeduction() async throws {
        _ = try await APIClient.shared.post("/api/chat/deduction", body: [:])
    }
}
