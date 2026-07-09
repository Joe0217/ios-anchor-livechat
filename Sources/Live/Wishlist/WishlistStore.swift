import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "WishlistStore")

/// 心愿单 store（对齐 H5 wishlist 数据流）
@MainActor
final class WishlistStore: ObservableObject {
    @Published private(set) var items: [WishlistItem] = []
    @Published private(set) var topGifters: [WishlistTop6Item] = []

    /// 用户主播昵称（半屏面板标题用；由外部注入）
    @Published var anchorNickname: String = ""

    private let service: WishlistServiceProtocol
    private var anchorUserId: String = ""
    private var top6Timer: Timer?

    init(service: WishlistServiceProtocol = WishlistServiceFakes()) {
        self.service = service
    }

    /// 进房初始化拉取
    func loadInitial(anchorUserId: String, anchorNickname: String) {
        self.anchorUserId = anchorUserId
        self.anchorNickname = anchorNickname
        Task { await loadItems() }
    }

    private func loadItems() async {
        do {
            items = try await service.fetchWishlist(anchorUserId: anchorUserId)
        } catch {
            logger.warning("Wishlist load failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// 半屏面板 onAppear 触发 Top6 拉取 + 启动 30s 轮询
    func onPanelAppear(liveRecordId: String) {
        Task { await loadTop6(liveRecordId: liveRecordId) }
        startTop6Polling(liveRecordId: liveRecordId)
    }

    /// 半屏面板 onDisappear 停止轮询
    func onPanelDisappear() {
        top6Timer?.invalidate()
        top6Timer = nil
    }

    private func loadTop6(liveRecordId: String) async {
        do {
            topGifters = try await service.fetchTop6(liveRecordId: liveRecordId,
                                                     anchorId: anchorUserId)
        } catch {
            logger.warning("Top6 load failed: \(String(describing: error), privacy: .private)")
        }
    }

    private func startTop6Polling(liveRecordId: String) {
        top6Timer?.invalidate()
        top6Timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.loadTop6(liveRecordId: liveRecordId)
            }
        }
    }

    /// 收礼推进进度（对齐 H5 handleLiveGiftMessage 里 compelteGiftNum 更新）
    func updateProgress(giftId: String, completedCount: Int) {
        guard let idx = items.firstIndex(where: { $0.id == giftId }) else { return }
        let old = items[idx]
        items[idx] = WishlistItem(id: old.id, giftName: old.giftName, giftIconUrl: old.giftIconUrl,
                                   giftPrice: old.giftPrice, targetCount: old.targetCount,
                                   completedCount: completedCount, promiseText: old.promiseText)
    }
}
