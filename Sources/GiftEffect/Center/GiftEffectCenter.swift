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
    /// var（而非 let）—— 让 HilyApp 冷启后 installPlayerRouter 替换成真 GiftPlayerRouter；
    /// 这样 Center.swift 自身与 SVGA/YYEVA SDK 完全解耦（能留 HilyTests 白名单）
    private var playerRouter: GiftPlayerRouting
    private weak var hostView: UIView?

    /// 硬中断标志位（2026-07-09 code-review P0 修复）：
    /// stopCurrentImmediately() 内 playerRouter.stopAll() 是**同步**fire onFinish 链路
    /// → Router closure → onPlayerFinished → playNextIfIdle → **若 pending 未清则会取下一条播**。
    /// 用 isTearingDown 让 playNextIfIdle 短路，配合 4 个入口后续 pending.removeAll，
    /// 保证切场景 / leave / memoryWarning / reset 时队尾 pending 不会跨场景/跨 teardown 意外触发。
    private var isTearingDown = false

    private static let queueLimit = 30

    public init(playerRouter: GiftPlayerRouting) {
        self.playerRouter = playerRouter
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMemoryWarningNoti),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil
        )
    }

    /// 用生产 router 替换默认 NoopGiftPlayerRouter；HilyApp 冷启完成时调（Task 7）。
    /// 幂等：多次调用后一次生效；替换前会 stopAll 释放当前动画。
    public func installPlayerRouter(_ router: GiftPlayerRouting) {
        playerRouter.stopAll()
        playerRouter.tearDownPlayers()
        playerRouter = router
        logger.info("installPlayerRouter: replaced with production router")
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
            // log 含 scene+scopeId 双字段，方便 debug key 不匹配（如业务 roomId vs 云信 yxRoomId 混用）
            let itemDesc = "\(item.sceneKey.scene.rawValue):\(item.sceneKey.scopeId)"
            let activeDesc = self.activeKey.map { "\($0.scene.rawValue):\($0.scopeId)" } ?? "nil"
            logger.warning("enqueue rejected: item=\(itemDesc, privacy: .public) active=\(activeDesc, privacy: .public)")
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
        // 标志位包裹整个 stopAll 同步链路：SVGA/YYEVA/Fake router 的 stop() 都会同步 fire
        // onFinish → Center.onPlayerFinished → playNextIfIdle 尝试消费 pending。
        // 若不 short-circuit，切场景瞬间会把当前场景 pending 队尾提前播（可能已跨到新场景 window）。
        isTearingDown = true
        playerRouter.stopAll()
        current = nil
        isTearingDown = false
    }

    private func playNextIfIdle() {
        // 硬中断进行中：不消费 pending（详见 isTearingDown 字段注释）
        guard !isTearingDown else { return }
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
