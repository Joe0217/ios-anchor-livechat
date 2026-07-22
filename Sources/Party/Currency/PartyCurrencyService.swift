import Foundation

/// 派对房房币服务的可注入边界。网络实现在 `DefaultPartyCurrencyService`。
protocol PartyCurrencyService: Sendable {
    func fetchBalance() async throws -> PartyCurrencyBalance
    func exchange(gems: Int64, target: PartyCurrencyTarget) async throws
}
