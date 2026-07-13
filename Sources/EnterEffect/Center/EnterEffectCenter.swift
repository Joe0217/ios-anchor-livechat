import Foundation
import UIKit
import Combine
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "EnterEffectCenter")

/// EnterEffect 中央 current 独立 Bridge
///
/// **独立于 GiftEffectCurrentBridge**：EnterEffectLayer 只订阅本 bridge，
/// GiftEffect 变化不触发本层重算，反之亦然
/// （对齐 .claude/rules/swiftui-keepalive-publisher-isolation.md §派生 Bridge 隔离）
@MainActor
public final class EnterEffectCurrentBridge: ObservableObject {
    @Published fileprivate(set) var current: GiftEffectItem?
}

/// 用户进场特效中央（座驾 SVGA/MP4 全屏播放）
///
/// **独立于 GiftEffectCenter**：完全独立的 pending 队列 + Player Router 实例，
/// 与 GiftEffect 完全并行播放（用户明示 "iOS 主播端需要把不同的特效队列分开，允许同时播放"）
///
/// **复用点**：
/// - `GiftEffectItem`（vehicle URL 直接映射到 `animationUrl` 字段，giftId=0/giftName="vehicle" 语义标记）
/// - `GiftEffectSceneKey`（scene+scopeId 共同 key 语义）
/// - `GiftPlayerRouting` protocol + `GiftPlayerRouter` 类（第二个独立实例，SVGA/YYEVA 都是实例字段天然并行）
/// - `GiftEffectOverlayWindow`（共用 UIWindow，Layer 加到 GiftEffectRoot ZStack）
///
/// **A1 修复**（对齐 workflow red-team A 反驳 1）：
/// playNextIfIdle 在 hostView / playerRouter 未 ready 时**不消费 pending**，
/// 让 registerHostView / installPlayerRouter 后主动 kick，避免 host-nil 分支
/// 静默 drop item 导致后续队列僵死
@MainActor
public final class EnterEffectCenter: ObservableObject {

    public static let shared: EnterEffectCenter = {
        EnterEffectCenter(playerRouter: NoopGiftPlayerRouter())
    }()

    /// 派生 Bridge：EnterEffectLayer 只订阅本 bridge
    public let currentBridge = EnterEffectCurrentBridge()

    @Published public private(set) var current: GiftEffectItem? {
        didSet { currentBridge.current = current }
    }

    private var pending: [GiftEffectItem] = []
    private var activeKey: GiftEffectSceneKey?

    /// 场景栈（对齐 GiftEffectCenter P0-3 修复）：
    /// setActiveScene push 旧 activeKey，leaveScene pop restore；
    /// 支持 Live→Call→回 Live 底层场景自动恢复
    private var sceneStack: [GiftEffectSceneKey] = []
    private static let sceneStackDepthLimit = 4

    private var playerRouter: GiftPlayerRouting
    private weak var hostView: UIView?

    /// 硬中断标志位（对齐 GiftEffectCenter P0-4 修复）：
    /// stopCurrentImmediately() 内 playerRouter.stopAll() 同步 fire onFinish 链路
    /// → onPlayerFinished → playNextIfIdle 会取下一条播 → 用 isTearingDown 短路
    private var isTearingDown = false

    private static let queueLimit = 15

    public init(playerRouter: GiftPlayerRouting) {
        self.playerRouter = playerRouter
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMemoryWarningNoti),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil
        )
    }

    // MARK: - Public API

    /// 用生产 router 替换默认 Noop router；HilyApp 冷启完成时调
    public func installPlayerRouter(_ router: GiftPlayerRouting) {
        isTearingDown = true
        playerRouter.stopAll()
        playerRouter.tearDownPlayers()
        current = nil
        playerRouter = router
        isTearingDown = false
        playNextIfIdle()   // 新 router 承接 pending
        logger.info("installPlayerRouter: replaced with production router")
    }

    public func registerHostView(_ view: UIView) {
        hostView = view
        // A1 修复：新 host 可能承接 hostView 未 ready 时被 defer 的 pending
        playNextIfIdle()
    }

    public func unregisterHostView(_ view: UIView) {
        if hostView === view { hostView = nil }
    }

    public func setActiveScene(_ key: GiftEffectSceneKey) {
        if activeKey == key { return }
        if let old = activeKey {
            sceneStack.append(old)
            if sceneStack.count > Self.sceneStackDepthLimit {
                sceneStack.removeFirst(sceneStack.count - Self.sceneStackDepthLimit)
            }
            stopCurrentImmediately()
            pending.removeAll()
        }
        sceneStack.removeAll { $0 == key }
        activeKey = key
        logger.info("setActiveScene → \(key.scene.rawValue, privacy: .public):\(key.scopeId, privacy: .public) stackDepth=\(self.sceneStack.count, privacy: .public)")
    }

    public func leaveScene(_ key: GiftEffectSceneKey) {
        // 正常 leave 路径
        if activeKey == key {
            stopCurrentImmediately()
            pending.removeAll()
            if let restored = sceneStack.popLast() {
                activeKey = restored
                logger.info("leaveScene ← \(key.scene.rawValue, privacy: .public):\(key.scopeId, privacy: .public) restored=\(restored.scene.rawValue, privacy: .public):\(restored.scopeId, privacy: .public)")
            } else {
                activeKey = nil
                logger.info("leaveScene ← \(key.scene.rawValue, privacy: .public):\(key.scopeId, privacy: .public) → nil")
            }
            return
        }
        // scopeId 时序错位容错（对齐 GiftEffectCenter P0-2 修复）
        if let active = activeKey, active.scene == key.scene {
            stopCurrentImmediately()
            pending.removeAll()
            if let restored = sceneStack.popLast() {
                activeKey = restored
            } else {
                activeKey = nil
            }
            logger.info("leaveScene scene-only match ← \(key.scene.rawValue, privacy: .public)")
            return
        }
        logger.debug("leaveScene ignored: key=\(key.scene.rawValue, privacy: .public):\(key.scopeId, privacy: .public) activeKey=\(self.activeKey?.scene.rawValue ?? "nil", privacy: .public)")
    }

    public func enqueue(_ item: GiftEffectItem) {
        // 主播自己进场 drop（H5 只有观众/客人进场消息经此路径，防御性过滤）
        if item.isSelfSent {
            logger.debug("enqueue drop: self-sent nickname=\(item.senderNickname, privacy: .public)")
            return
        }
        // Scene gate（对齐 GiftEffectCenter enqueue 单点判定）
        guard let active = activeKey, active == item.sceneKey else {
            let itemDesc = "\(item.sceneKey.scene.rawValue):\(item.sceneKey.scopeId)"
            let activeDesc = self.activeKey.map { "\($0.scene.rawValue):\($0.scopeId)" } ?? "nil"
            logger.warning("enqueue rejected: item=\(itemDesc, privacy: .public) active=\(activeDesc, privacy: .public)")
            return
        }
        pending.append(item)
        while pending.count > Self.queueLimit {
            let dropped = pending.removeFirst()
            logger.info("queue overflow dropped: nickname=\(dropped.senderNickname, privacy: .public)")
        }
        playNextIfIdle()
    }

    public func reset() {
        stopCurrentImmediately()
        pending.removeAll()
        activeKey = nil
        sceneStack.removeAll()
        playerRouter.tearDownPlayers()
    }

    public func warmupSVGA() {
        playerRouter.warmupSVGA()
    }

    public func handleMemoryWarning() {
        stopCurrentImmediately()
        pending.removeAll()
        logger.warning("memory warning: cleared in-flight")
    }

    @objc private func handleMemoryWarningNoti() { handleMemoryWarning() }

    // MARK: - Private

    private func stopCurrentImmediately() {
        isTearingDown = true
        playerRouter.stopAll()
        current = nil
        isTearingDown = false
    }

    private func playNextIfIdle() {
        guard !isTearingDown else { return }
        guard current == nil, !pending.isEmpty else { return }
        // A1 修复：hostView 未 ready 时不消费 pending，让 registerHostView 后 kick
        guard let host = hostView else {
            logger.warning("playNextIfIdle deferred: hostView not ready (pending=\(self.pending.count, privacy: .public))")
            return
        }
        let next = pending.removeFirst()
        current = next
        // onFinish 保证在主线程回调（GiftAnimationPlayer protocol 契约）
        playerRouter.play(item: next, in: host) { [weak self] in
            self?.onPlayerFinished()
        }
    }

    private func onPlayerFinished() {
        current = nil
        playNextIfIdle()
    }
}
