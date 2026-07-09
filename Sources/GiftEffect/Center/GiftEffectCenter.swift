import Foundation
import UIKit
import Combine
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "GiftEffectCenter")

@MainActor
public final class GiftEffectCenter: ObservableObject {

    /// 默认单例（生产用）。UT 时用 init(playerRouter:) 注入 fake。
    public static let shared: GiftEffectCenter = {
        GiftEffectCenter(playerRouter: NoopGiftPlayerRouter())
    }()

    @Published public private(set) var current: GiftEffectItem?
    @Published public private(set) var microToasts: [MicroToastItem] = []

    private var pending: [GiftEffectItem] = []
    private var activeKey: GiftEffectSceneKey?
    private let playerRouter: GiftPlayerRouting
    private weak var hostView: UIView?

    private static let queueLimit = 30

    public init(playerRouter: GiftPlayerRouting) {
        self.playerRouter = playerRouter
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMemoryWarningNoti),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil
        )
    }

    public func registerHostView(_ view: UIView) { hostView = view }
    public func unregisterHostView(_ view: UIView) {
        if hostView === view { hostView = nil }
    }

    public func setActiveScene(_ key: GiftEffectSceneKey) {
        if activeKey == key { return }
        if activeKey != nil {
            stopCurrentImmediately()
            pending.removeAll()
            microToasts.removeAll()
        }
        activeKey = key
        logger.info("setActiveScene → \(key.scene.rawValue, privacy: .public):\(key.scopeId, privacy: .public)")
    }

    public func leaveScene(_ key: GiftEffectSceneKey) {
        guard activeKey == key else { return }
        stopCurrentImmediately()
        pending.removeAll()
        microToasts.removeAll()
        activeKey = nil
        logger.info("leaveScene ← \(key.scene.rawValue, privacy: .public):\(key.scopeId, privacy: .public)")
    }

    public func enqueue(_ item: GiftEffectItem) {
        guard let active = activeKey, active == item.sceneKey else {
            logger.warning("enqueue rejected: item=\(item.sceneKey.scene.rawValue, privacy: .public) active=\(self.activeKey?.scene.rawValue ?? "nil", privacy: .public)")
            return
        }
        if item.sceneKey.scene == .party && item.isSelfSent {
            pending.insert(item, at: 0)
            logger.info("party me-sent gift head-inserted: \(item.giftName, privacy: .public)")
        } else {
            pending.append(item)
        }
        while pending.count > Self.queueLimit {
            let dropped = pending.removeFirst()
            logger.info("queue overflow dropped: \(dropped.giftName, privacy: .public)")
        }
        playNextIfIdle()
    }

    public func showMicroToast(_ toast: MicroToastItem) {
        guard let active = activeKey, active == toast.sceneKey else { return }
        guard active.scene != .chat else { return }
        microToasts.append(toast)
        let id = toast.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(toast.duration * 1_000_000_000))
            self?.microToasts.removeAll { $0.id == id }
        }
    }

    public func handleMemoryWarning() {
        stopCurrentImmediately()
        pending.removeAll()
        microToasts.removeAll()
        logger.warning("memory warning: cleared in-flight")
    }

    public func reset() {
        stopCurrentImmediately()
        pending.removeAll()
        microToasts.removeAll()
        activeKey = nil
        playerRouter.tearDownPlayers()
    }

    public func warmupSVGA() {
        playerRouter.warmupSVGA()
    }

    @objc private func handleMemoryWarningNoti() { handleMemoryWarning() }

    private func stopCurrentImmediately() {
        playerRouter.stopAll()
        current = nil
    }

    private func playNextIfIdle() {
        guard current == nil, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        current = next
        guard let host = hostView else {
            // 无 hostView 场景（UT 或 window 未挂）—— 直接 finish 推动队列
            logger.warning("no hostView: skipping player, treating as finished immediately")
            onPlayerFinished()
            return
        }
        // onFinish 保证在 @MainActor 主线程回调（GiftAnimationPlayer protocol 契约），
        // 直接同步 onPlayerFinished 推进队列，无需 Task hop
        playerRouter.play(item: next, in: host) { [weak self] in
            self?.onPlayerFinished()
        }
    }

    private func onPlayerFinished() {
        current = nil
        playNextIfIdle()
    }
}

// MARK: - No-op router（Task 5 前占位）

@MainActor
final class NoopGiftPlayerRouter: GiftPlayerRouting {
    func play(item: GiftEffectItem, in host: UIView, onFinish: @escaping () -> Void) {
        onFinish()
    }
    func stopAll() {}
    func tearDownPlayers() {}
    func warmupSVGA() {}
}
