import Foundation
import os

private let guardianStoreLogger = Logger(subsystem: "com.anchor.livechat", category: "GuardianStore")

/// 直播顶部守护人数。H5 在进房和本房 146 广播到达后重拉 panel，此处保持同一节奏。
@MainActor
final class GuardianCountStore: ObservableObject {
    @Published private(set) var guardianCount = 0

    private let service: GuardianServiceProtocol
    private var requestTask: Task<Void, Never>?

    init(service: GuardianServiceProtocol = GuardianService()) {
        self.service = service
    }

    deinit {
        requestTask?.cancel()
    }

    func load(anchorId: Int64) {
        guard anchorId > 0 else {
            guardianCount = 0
            return
        }
        requestTask?.cancel()
        requestTask = Task { [weak self, service] in
            do {
                let panel = try await service.fetchPanel(anchorId: anchorId)
                try Task.checkCancellation()
                guard let self else { return }
                self.guardianCount = panel.guardianCount
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                // 与 H5 相同：顶部入口仍可点，失败时只隐藏人数角标，不用错误面板阻断直播。
                self.guardianCount = 0
                guardianStoreLogger.warning("Guardian count load failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    func clear() {
        requestTask?.cancel()
        requestTask = nil
        guardianCount = 0
    }
}

/// 直播详情弹层的数据状态。H5 面板字段不足以打开榜一资料，因此额外请求 list 第 1 页补齐 uid/等级。
@MainActor
final class GuardianDetailStore: ObservableObject {
    @Published private(set) var panel: GuardianPanel
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    let anchorId: Int64
    private let service: GuardianServiceProtocol
    private var requestTask: Task<Void, Never>?

    init(anchorId: Int64, service: GuardianServiceProtocol = GuardianService()) {
        self.anchorId = anchorId
        self.service = service
        self.panel = GuardianPanel.fallback(anchorId: anchorId)
    }

    deinit {
        requestTask?.cancel()
    }

    func load() {
        guard anchorId > 0 else { return }
        requestTask?.cancel()
        isLoading = true
        errorMessage = nil
        requestTask = Task { [weak self, service, anchorId] in
            do {
                var loadedPanel = try await service.fetchPanel(anchorId: anchorId)
                try Task.checkCancellation()

                // H5 adapter 的 panel 不含 top1 uid / level，只有榜一存在时才做这次非阻断补齐请求。
                if loadedPanel.topGuardian != nil {
                    do {
                        let firstPage = try await service.fetchList(anchorId: anchorId, page: 1, pageSize: 1)
                        try Task.checkCancellation()
                        if let top = firstPage.items.first, var existing = loadedPanel.topGuardian {
                            existing = GuardianTopUser(
                                userId: top.id,
                                nickname: existing.nickname ?? top.nickname,
                                avatarURL: existing.avatarURL ?? top.avatarURL,
                                level: top.level
                            )
                            loadedPanel.topGuardian = existing
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // 详情本体已有可用 panel，榜一资料补齐失败不降级整个面板。
                        guardianStoreLogger.warning("Guardian top user supplement failed: \(String(describing: error), privacy: .private)")
                    }
                }

                guard let self else { return }
                self.panel = loadedPanel
                self.isLoading = false
                AnalyticsTracker.track(
                    "h_guardian_detail_page_view",
                    properties: ["guardian_count": "\(loadedPanel.guardianCount)"]
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.isLoading = false
                self.errorMessage = error.localizedDescription
                guardianStoreLogger.error("Guardian detail load failed: \(String(describing: error), privacy: .private)")
            }
        }
    }
}

/// 守护者列表分页状态。刷新时保留原列表，避免网络抖动让已展示的榜单闪成空白。
@MainActor
final class GuardianListStore: ObservableObject {
    @Published private(set) var items: [GuardianListItem] = []
    @Published private(set) var total = 0
    @Published private(set) var isInitialLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = true
    @Published private(set) var errorMessage: String?

    private let anchorId: Int64
    private let service: GuardianServiceProtocol
    private var requestTask: Task<Void, Never>?
    private var currentPage = 0
    private let pageSize = 20

    init(anchorId: Int64, service: GuardianServiceProtocol = GuardianService()) {
        self.anchorId = anchorId
        self.service = service
    }

    deinit {
        requestTask?.cancel()
    }

    func loadInitialIfNeeded() {
        guard items.isEmpty, !isInitialLoading else { return }
        reload()
    }

    func reload() {
        guard anchorId > 0 else { return }
        requestTask?.cancel()
        let hadItems = !items.isEmpty
        isInitialLoading = !hadItems
        isRefreshing = hadItems
        isLoadingMore = false
        errorMessage = nil
        request(page: 1, replacing: true)
    }

    func loadMoreIfNeeded(currentItem: GuardianListItem?) {
        guard let currentItem,
              currentItem.id == items.last?.id,
              hasMore,
              !isInitialLoading,
              !isRefreshing,
              !isLoadingMore else { return }
        request(page: currentPage + 1, replacing: false)
    }

    private func request(page: Int, replacing: Bool) {
        guard anchorId > 0 else { return }
        if !replacing {
            isLoadingMore = true
        }
        requestTask = Task { [weak self, service, anchorId, pageSize] in
            do {
                let response = try await service.fetchList(anchorId: anchorId, page: page, pageSize: pageSize)
                try Task.checkCancellation()
                guard let self else { return }

                if replacing {
                    self.items = response.items
                } else {
                    let existing = Set(self.items.map(\.id))
                    self.items.append(contentsOf: response.items.filter { !existing.contains($0.id) })
                }
                self.total = response.total
                self.currentPage = response.page
                self.hasMore = response.hasMore && !response.items.isEmpty
                self.isInitialLoading = false
                self.isRefreshing = false
                self.isLoadingMore = false
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.isInitialLoading = false
                self.isRefreshing = false
                self.isLoadingMore = false
                self.errorMessage = error.localizedDescription
                guardianStoreLogger.error("Guardian list load failed page=\(page, privacy: .public): \(String(describing: error), privacy: .private)")
            }
        }
    }
}
