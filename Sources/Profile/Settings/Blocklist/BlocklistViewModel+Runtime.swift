import Foundation

/// runtime 工厂入口：注入 `BlocklistService.shared` 默认服务 + L10n 兜底文案。
///
/// **不入 HilyTests sources**（依赖 L10n + BlocklistService，HilyTests 用 FakeBlocklistService
/// 直接构造 ViewModel）。trial #1 Cycle +Label.swift 同款拆法。
extension BlocklistViewModel {
    @MainActor
    static func makeRuntime() -> BlocklistViewModel {
        BlocklistViewModel(
            service: BlocklistService.shared,
            pageSize: 20,
            networkErrorFallback: L10n.blocklistRemoveNetworkError,
            badUserIdFallback: L10n.blocklistRemoveBadUserId
        )
    }
}
