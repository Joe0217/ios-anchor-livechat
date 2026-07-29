import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "GiftAnimQueue")

/// 送礼动画队列（对齐 H5 giftStore.giftQueue 模型）
///
/// 关键规则：
/// - 同时**仅 1 条**动画播放（Overlay 单例）
/// - 播放完成自动 shift 出队并播下一条
/// - PK 期间按 price 降序 + timestamp 升序排序 + 队长限 15（H5 sortAndLimitPkGiftQueue）
///
/// @Published 只暴露 `current`（当前播放条），避免 `queue: [Item]` 高频变化让 SwiftUI overlay 频繁重算
@MainActor
final class GiftAnimationQueue: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let giftIconUrl: String?     // 后端下发 SVGA/MP4 URL（Stub 模式忽略）
        let giftName: String         // 显示 fallback（Stub 模式主要展示）
        let price: Int               // 用于 PK 期间排序
        let count: Int
        let senderNickname: String
        let senderAvatarUrl: String?
        let timestamp: Int64
    }

    /// 当前播放（nil = 无动画）
    @Published private(set) var current: Item?

    /// 内部队列（非 @Published 避免频繁 body 重算）
    private var pending: [Item] = []
    private var isPlaying: Bool = false
    /// 离房 clear 后，旧播放器的完成回调不能接管后续房间的队列。
    private var generation = 0

    /// PK 中标记（外部由 PKStore 状态变化调 setIsInPK）
    private var isInPK: Bool = false
    /// PK 期间队长限（对齐 H5 `pkGiftQueueLimit = 15`）
    private let pkQueueLimit: Int = 15

    private let player: GiftAnimationPlayerProtocol

    init(player: GiftAnimationPlayerProtocol = StubGiftAnimationPlayer()) {
        self.player = player
    }

    /// 添加一条动画到队列
    func addToQueue(_ item: Item) {
        pending.append(item)
        if isInPK {
            sortAndLimitPkQueue()
        }
        logger.info("Gift enqueued: \(item.giftName, privacy: .public) count=\(item.count)")
        playNextIfIdle()
    }

    /// PK 状态切换
    func setIsInPK(_ inPK: Bool) {
        isInPK = inPK
        if inPK { sortAndLimitPkQueue() }
    }

    /// 清空（例如离开直播间）
    func clear() {
        generation &+= 1
        pending.removeAll()
        current = nil
        isPlaying = false
    }

    // MARK: - Private

    /// PK 期间：按 price 降序 + timestamp 升序排 + 截断至 pkQueueLimit（对齐 H5 sortAndLimitPkGiftQueue）
    private func sortAndLimitPkQueue() {
        pending.sort { l, r in
            if l.price != r.price { return l.price > r.price }
            return l.timestamp < r.timestamp
        }
        if pending.count > pkQueueLimit {
            pending = Array(pending.prefix(pkQueueLimit))
        }
    }

    private func playNextIfIdle() {
        guard !isPlaying, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        current = next
        isPlaying = true
        let expectedGeneration = generation
        player.play(url: next.giftIconUrl) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.generation == expectedGeneration, self.current?.id == next.id else { return }
                self.current = nil
                self.isPlaying = false
                self.playNextIfIdle()
            }
        }
    }
}
