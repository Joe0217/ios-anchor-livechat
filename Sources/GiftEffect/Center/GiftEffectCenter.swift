import Foundation
import UIKit
import Combine
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "GiftEffectCenter")

/// 中央大动画 bridge（2026-07-10 code-review E-4 修复）：
/// 独立发布 current，Central Layer 只订阅本 bridge，避免 microToasts 变化触发 Central re-body。
/// 对齐 .claude/rules/swiftui-keepalive-publisher-isolation.md §派生 bridge 方案 A。
@MainActor
public final class GiftEffectCurrentBridge: ObservableObject {
    @Published fileprivate(set) var current: GiftEffectItem?
}

/// MicroToast bridge：独立发布 microToasts，MicroToast Layer 只订阅本 bridge。
@MainActor
public final class GiftEffectMicroToastBridge: ObservableObject {
    @Published fileprivate(set) var toasts: [MicroToastItem] = []
}

@MainActor
public final class GiftEffectCenter: ObservableObject {

    /// 默认单例（生产用）。UT 时用 init(playerRouter:) 注入 fake。
    public static let shared: GiftEffectCenter = {
        GiftEffectCenter(playerRouter: NoopGiftPlayerRouter())
    }()

    /// E-4 派生 bridge：两个 Layer 分别订阅，避免单一 @Published 触发双 Layer 重算
    public let currentBridge = GiftEffectCurrentBridge()
    public let microToastBridge = GiftEffectMicroToastBridge()

    @Published public private(set) var current: GiftEffectItem? {
        didSet { currentBridge.current = current }
    }
    @Published public private(set) var microToasts: [MicroToastItem] = [] {
        didSet { microToastBridge.toasts = microToasts }
    }

    private var pending: [GiftEffectItem] = []
    private var activeKey: GiftEffectSceneKey?

    /// 场景栈（2026-07-10 code-review P0-3 修复）：
    /// setActiveScene push 旧 activeKey，leaveScene pop restore；支持
    /// Live→Call→回 Live / Chat→Call→回 Chat / Party→Call→回 Party 自动恢复。
    /// 根因：CallView 通过 RootView ZStack 条件插入非 push，Live/Chat/Party 底层 view
    /// 不 disappear，其 modifier onAppear 挂载时只跑一次；私 call 结束 leaveScene(.call)
    /// 后无路径恢复底层 scene。用栈自动 restore。
    private var sceneStack: [GiftEffectSceneKey] = []
    private static let sceneStackDepthLimit = 4   // 一般不会超 3（chat→call→matchpreview 类深），4 保底防泄漏

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
    ///
    /// 2026-07-10 code-review P0-4 修复：用 isTearingDown 包裹 stopAll+teardown+swap，
    /// 防止老 router 同步 fire onFinish → playNextIfIdle 消费 pending 后 tearDown
    /// 撕碎老 SDK 实例（触发场景：logout→login 内 pending 已累积）。swap 后主动
    /// playNextIfIdle 让新 router 承接 pending。
    public func installPlayerRouter(_ router: GiftPlayerRouting) {
        isTearingDown = true
        playerRouter.stopAll()
        playerRouter.tearDownPlayers()
        current = nil
        playerRouter = router
        isTearingDown = false
        playNextIfIdle()   // 新 router 承接残留 pending（若有）
        logger.info("installPlayerRouter: replaced with production router")
    }

    public func registerHostView(_ view: UIView) { hostView = view }
    public func unregisterHostView(_ view: UIView) {
        if hostView === view { hostView = nil }
    }

    /// 切换活跃场景。旧 activeKey 会 push 到 sceneStack（未来 leaveScene 时 pop restore）。
    /// 硬中断当前播放 + 清 pending/microToasts。幂等：同 key 不变。
    public func setActiveScene(_ key: GiftEffectSceneKey) {
        if activeKey == key { return }
        if let old = activeKey {
            // push 旧 scene 到栈；栈深超上限时丢最老（防止意外泄漏无限增长）
            sceneStack.append(old)
            if sceneStack.count > Self.sceneStackDepthLimit {
                sceneStack.removeFirst(sceneStack.count - Self.sceneStackDepthLimit)
            }
            stopCurrentImmediately()
            pending.removeAll()
            microToasts.removeAll()
        }
        // 若栈里有相同 key，是"回到之前场景"—— 移除该 key 避免栈泄漏
        sceneStack.removeAll { $0 == key }
        activeKey = key
        logger.info("setActiveScene → \(key.scene.rawValue, privacy: .public):\(key.scopeId, privacy: .public) stackDepth=\(self.sceneStack.count, privacy: .public)")
    }

    /// 离开场景。若 sceneStack 有栈顶则 pop restore；否则 activeKey=nil。
    /// 硬中断当前播放 + 清 pending/microToasts。
    ///
    /// 2026-07-10 code-review P0-2/P0-3 修复：栈式 restore 支持从 CallView overlay
    /// 恢复底层 Live/Chat/Party 场景；且对 scopeId 空/不同的容错通过 popLast() 自然处理。
    public func leaveScene(_ key: GiftEffectSceneKey) {
        // key 匹配 activeKey：正常 leave 路径
        if activeKey == key {
            stopCurrentImmediately()
            pending.removeAll()
            microToasts.removeAll()
            if let restored = sceneStack.popLast() {
                activeKey = restored
                logger.info("leaveScene ← \(key.scene.rawValue, privacy: .public):\(key.scopeId, privacy: .public) restored=\(restored.scene.rawValue, privacy: .public):\(restored.scopeId, privacy: .public)")
            } else {
                activeKey = nil
                logger.info("leaveScene ← \(key.scene.rawValue, privacy: .public):\(key.scopeId, privacy: .public) → nil")
            }
            return
        }
        // key 不匹配 activeKey：可能是 scopeId 时序错位（如 CallView.onDisappear 时 store.current.callId 已清空）
        // 只要 scene 匹配就走 restore 路径 —— 防止 activeKey 永久卡在 stale scopeId
        if let active = activeKey, active.scene == key.scene {
            stopCurrentImmediately()
            pending.removeAll()
            microToasts.removeAll()
            if let restored = sceneStack.popLast() {
                activeKey = restored
                logger.info("leaveScene scene-only match ← \(key.scene.rawValue, privacy: .public) restored=\(restored.scene.rawValue, privacy: .public)")
            } else {
                activeKey = nil
                logger.info("leaveScene scene-only match ← \(key.scene.rawValue, privacy: .public) → nil")
            }
            return
        }
        // 完全不匹配：可能是 view 层错误 double-leave，忽略
        logger.debug("leaveScene ignored: key=\(key.scene.rawValue, privacy: .public):\(key.scopeId, privacy: .public) activeKey=\(self.activeKey?.scene.rawValue ?? "nil", privacy: .public)")
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
            // 2026-07-10 code-review P0-1 修复：party me 队首插入前先 removeLast 让位，
            // 避免随后 while > 30 removeFirst 立即淘汰刚插入的 ME（原逻辑使 me 优先级归零）
            if pending.count >= Self.queueLimit {
                let dropped = pending.removeLast()
                logger.info("party me-sent yield tail for head-insert: dropped=\(dropped.giftName, privacy: .public)")
            }
            pending.insert(item, at: 0)
            logger.info("party me-sent gift head-inserted: \(item.giftName, privacy: .public)")
        } else {
            pending.append(item)
            while pending.count > Self.queueLimit {
                let dropped = pending.removeFirst()
                logger.info("queue overflow dropped: \(dropped.giftName, privacy: .public)")
            }
        }
        playNextIfIdle()
    }

    public func showMicroToast(_ toast: MicroToastItem) {
        guard let active = activeKey, active == toast.sceneKey else { return }
        guard active.scene != .chat else { return }
        // 2026-07-10 code-review E-3 修复：MicroToast cap 3（View 只渲染 .last，多的都是浪费）；
        // 突发时替换旧的而非无限 append，避免 O(n) removeAll + 大量 Task sleep 并发
        let cap = 3
        if microToasts.count >= cap {
            microToasts.removeFirst(microToasts.count - (cap - 1))
        }
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
        sceneStack.removeAll()
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
