#if DEBUG
import Foundation

/// Props 数据层 Fake（M1 Step 1a · spec §3.4 · 单测 + Preview 用 · 覆盖 §5.3 Fakes ↔ R 对应表）。
///
/// **场景通过 script 配置**，每次调用消费一步或使用 `default` 反复返回。
final class PropsServiceFake: PropsService, @unchecked Sendable {

    /// 单次调用的响应
    enum Response {
        case page(PropPage)
        case pageError(PropsServiceError)
        case ops(Void)
        case opsError(PropsServiceError)
    }

    /// 请求 script（按顺序消费；空则 fall back 到 default）
    private let queue: NSLock = .init()
    private var scriptedResponses: [Response] = []
    private var defaultResponse: Response?

    /// 网络延迟（用于测竞态 · R1/R2）
    var artificialDelay: TimeInterval = 0

    /// 记录调用参数（供单测断言）
    private(set) var recordedFetchPage: [(itemType: PropTabItemType?, pageIndex: Int, pageSize: Int)] = []
    private(set) var recordedOps: [(itemId: Int64, action: PropEquipAction)] = []

    init() {}

    // MARK: - Script API

    /// 追加一组按顺序返回的 responses（消费完后无 fallback 走 default）
    func enqueue(_ responses: [Response]) {
        queue.lock(); defer { queue.unlock() }
        scriptedResponses.append(contentsOf: responses)
    }

    func enqueue(_ response: Response) {
        enqueue([response])
    }

    /// 设置默认响应（scripted 消费完后回落）
    func setDefault(_ response: Response) {
        queue.lock(); defer { queue.unlock() }
        defaultResponse = response
    }

    /// 便利：单成功 page
    func setPage(_ page: PropPage) {
        setDefault(.page(page))
    }

    /// 便利：直接压入一组 page 序列（用于分页测试）
    func setPages(_ pages: [PropPage]) {
        enqueue(pages.map { .page($0) })
    }

    /// 清空
    func reset() {
        queue.lock(); defer { queue.unlock() }
        scriptedResponses.removeAll()
        defaultResponse = nil
        artificialDelay = 0
        recordedFetchPage.removeAll()
        recordedOps.removeAll()
    }

    // MARK: - PropsService

    func fetchPage(
        itemType: PropTabItemType?,
        pageIndex: Int,
        pageSize: Int
    ) async throws -> PropPage {
        queue.lock()
        recordedFetchPage.append((itemType, pageIndex, pageSize))
        queue.unlock()

        try await delayIfNeeded()

        let response = dequeue()
        switch response {
        case .page(let page): return page
        case .pageError(let err): throw err
        case .ops, .opsError:
            throw PropsServiceError.decodeFailed("PropsServiceFake mismatched: expected page got ops")
        case .none:
            throw PropsServiceError.decodeFailed("PropsServiceFake no response set")
        }
    }

    func equipOps(itemId: Int64, action: PropEquipAction) async throws {
        queue.lock()
        recordedOps.append((itemId, action))
        queue.unlock()

        try await delayIfNeeded()

        let response = dequeue()
        switch response {
        case .ops: return
        case .opsError(let err): throw err
        case .page, .pageError:
            throw PropsServiceError.decodeFailed("PropsServiceFake mismatched: expected ops got page")
        case .none:
            throw PropsServiceError.decodeFailed("PropsServiceFake no response set")
        }
    }

    // MARK: - Internal

    private func dequeue() -> Response? {
        queue.lock(); defer { queue.unlock() }
        if !scriptedResponses.isEmpty {
            return scriptedResponses.removeFirst()
        }
        return defaultResponse
    }

    private func delayIfNeeded() async throws {
        guard artificialDelay > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(artificialDelay * 1_000_000_000))
    }
}

// MARK: - Preview / Fixture Helpers

extension PropItem {
    /// Preview / 单测便利：一个已拥有已穿戴的头像框
    static let previewFrameEquipped = PropItem(
        id: 1001, itemType: .frame, itemName: "Golden Frame",
        itemImg: "https://example.com/frames/gold.svga",
        itemSmallImg: "https://example.com/frames/gold_small.png",
        isFromBag: 1, wearStatus: 1, expireTime: .timestamp(Date().timeIntervalSince1970 + 86400 * 7)
    )
    /// 未拥有座驾
    static let previewVehicleLocked = PropItem(
        id: 2001, itemType: .vehicle, itemName: "Fire Dragon",
        itemImg: "https://example.com/vehicles/dragon.mp4",
        itemSmallImg: "https://example.com/vehicles/dragon_small.png",
        isFromBag: 0, wearStatus: 0, expireTime: .permanent
    )
    /// 永久聊天气泡
    static let previewChatSkinPermanent = PropItem(
        id: 4001, itemType: .chatSkin, itemName: "Neon Bubble",
        itemImg: "https://example.com/skins/neon.png",
        isFromBag: 1, wearStatus: 0, expireTime: .permanent
    )
}

extension PropPage {
    static let previewEmpty = PropPage(records: [], totalNum: 0)
    static let previewSmall = PropPage(records: [
        .previewFrameEquipped, .previewVehicleLocked, .previewChatSkinPermanent
    ], totalNum: 3)
}
#endif
