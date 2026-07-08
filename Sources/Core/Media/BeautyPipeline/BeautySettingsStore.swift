import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "BeautySettingsStore")

/// 美颜参数共享 Store（K spec §3 + §6.1 #3）。
///
/// 设计要点：
/// - `@MainActor` + ObservableObject：跨模块单例订阅，SwiftUI 直接 `@ObservedObject`
/// - `settings` `@Published`：任何 view 直读 + Sharer 层订阅广播到 renderer
/// - **flushIfDirty 幂等**（红队 A1）：NSLock + isFlushInProgress guard 防重入。
///   虽然 `@MainActor` 已保证串行，NSLock 是 defense in depth（若未来改成非-MainActor 也不炸）
/// - **读盘失败兜底默认档**（`.claude/rules/async-state-fallback.md`）：不 crash 不 dead-state
/// - **reset() 串行**（红队 A4）：Store 内部 mutation + flush 都在 MainActor 上，天然串行
/// - **revert()**：丢弃 in-memory 未保存修改，恢复到 lastPersisted（磁盘真值）
///
/// 使用：
/// ```
/// let store = BeautySettingsStore(persistence: UserDefaultsBeautyPersistence())
/// store.mutate { $0.blur = 70 }   // 拖滑块 —— 仅改 in-memory
/// store.flushIfDirty()            // 顶部 Save 按钮显式触发
/// store.revert()                  // 用户 Exit 丢弃未保存修改
/// store.reset()                   // Recover 恢复默认档
/// ```
@MainActor
final class BeautySettingsStore: ObservableObject {
    /// 当前参数（Publisher 广播到订阅者）
    @Published private(set) var settings: BeautySettings

    /// 最近一次成功持久化的快照（用于 dirty 检测 + reset 比对）
    private var lastPersisted: BeautySettings

    /// 上次读盘/写盘失败原因（供 UI 层做降级横幅）
    @Published private(set) var lastPersistenceError: BeautyError?

    /// dirty 状态（settings != lastPersisted）
    var isDirty: Bool { settings != lastPersisted }

    private let persistence: BeautySettingsPersistence

    // MARK: - flush 幂等锁（红队 A1）
    private let flushLock = NSLock()
    private var isFlushInProgress = false

    // MARK: - init：读盘 or 默认档
    init(persistence: BeautySettingsPersistence) {
        self.persistence = persistence

        // 读盘失败兜底默认档（`.claude/rules/async-state-fallback.md`）
        var loaded: BeautySettings = .defaults
        do {
            if let disk = try persistence.load() {
                loaded = disk
            }
            // else: key 不存在 = 首次进入，走 defaults
        } catch let error as BeautyError {
            logger.warning("BeautySettingsStore load failed, using defaults: \(String(describing: error))")
            self.lastPersistenceError = error
        } catch {
            logger.warning("BeautySettingsStore load unknown error: \(String(describing: error))")
            self.lastPersistenceError = .persistenceDecodeFailed(reason: String(describing: error))
        }
        self.settings = loaded
        self.lastPersisted = loaded
    }

    // MARK: - Update APIs（拖滑块调用，dirty 标记自动跟随 settings != lastPersisted）
    //
    // 单参数 setter 让 SwiftUI Binding 更细粒度；也可直接 store.mutate { $0.whiten = ... }
    func mutate(_ block: (inout BeautySettings) -> Void) {
        var copy = settings
        block(&copy)
        settings = copy
    }

    // MARK: - flushIfDirty（红队 A1 幂等）
    /// 触发时机（2026-07-08 澄清后仅显式路径）：
    /// - 顶部 `Save` 按钮
    /// - Store.reset() 内部（reset 后立即写盘，恢复默认档不留 in-memory dirty）
    ///
    /// 幂等策略：若 in-flight 直接 no-op；写盘完成后释放 flag。
    /// 返回 true = 本次真触发写盘；false = no-op（in-flight or !dirty）
    @discardableResult
    func flushIfDirty() -> Bool {
        // 幂等锁 acquire
        flushLock.lock()
        if isFlushInProgress {
            flushLock.unlock()
            return false
        }
        guard settings != lastPersisted else {
            flushLock.unlock()
            return false
        }
        isFlushInProgress = true
        flushLock.unlock()

        // 释放锁后再写盘（避免长持锁；MainActor 本身仍串行）
        let snapshot = settings
        defer {
            flushLock.lock()
            isFlushInProgress = false
            flushLock.unlock()
        }

        do {
            try persistence.save(snapshot)
            lastPersisted = snapshot
            lastPersistenceError = nil
            return true
        } catch let error as BeautyError {
            logger.warning("BeautySettingsStore flush failed: \(String(describing: error))")
            lastPersistenceError = error
            return false
        } catch {
            logger.warning("BeautySettingsStore flush unknown error: \(String(describing: error))")
            lastPersistenceError = .persistenceWriteFailed(reason: String(describing: error))
            return false
        }
    }

    // MARK: - reset 恢复默认（K spec §2.4 D8 + 红队 A4）
    /// 重置到业务默认档 + 立即写盘（不等 onDisappear）。
    /// 串行保证：MainActor + flushIfDirty 幂等锁，reset 中的 flush 与并发 flush 不双写。
    @discardableResult
    func reset() -> Bool {
        settings = .defaults
        return flushIfDirty()
    }

    // MARK: - revert 丢弃未保存修改（K spec §2.4 X 按钮 exitConfirm.discard）
    /// 把 settings 还原为最近一次持久化的值（磁盘上真值），清空 in-memory dirty 状态。
    /// 用于：用户点"Exit"丢弃未保存修改 / view 真 dismount 时兜底防止 store 残留 dirty state
    /// 影响下次进入。幂等——settings 已经等于 lastPersisted 时 no-op（无 objectWillChange fire）。
    func revert() {
        guard settings != lastPersisted else { return }
        settings = lastPersisted
    }
}
