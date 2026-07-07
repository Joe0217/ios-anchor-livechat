import Combine
import Foundation

/// v5.5 空闲清理机制的 runtime 接线（bubbly-leaping-comet plan）。
///
/// **拆分原因**：`AutoOfflineMonitor` 依赖 SwiftUI/UIKit，`CallStore` 依赖声网/云信 SDK；
/// 二者不入 HilyTests target sources，故本 extension 独立成文件，不列入 test sources
/// 让核心清理逻辑（`performIdleCleanupWithProtection`）保持纯 Swift + 可单测。
/// 对齐 [BlocklistViewModel+Runtime.swift](../Profile/Settings/Blocklist/BlocklistViewModel+Runtime.swift) 已有实践。
///
/// **wiring 时机**：由 `MessageSessionStore.shared` 静态构造后立即调用 `attachAutoOfflineObserver()`
/// （见 `MessageSessionStoreShared.swift`）。
extension MessageSessionStore {

    /// 挂 AutoOffline 弹窗展示瞬间的 sink：`showDialog=true` → 触发一次条件性清理。
    /// AutoOfflineMonitor 本身已由 CallStore/LiveStore/PartyStore `suspend()` 保护，
    /// 弹窗展示 = 用户真正空闲信号（不在通话/直播/派对房）。
    func attachAutoOfflineObserver() {
        AutoOfflineMonitor.shared.$showDialog
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.performIdleCleanup()
                }
            }
            .store(in: &cancellables)
    }

    /// AutoOffline 弹窗触发的清理入口。读 `CallStore.shared` 得通话中对端 id，
    /// 委托 `performIdleCleanupWithProtection` 实际清理。
    func performIdleCleanup() async {
        let activeCallPeerId: String? = {
            guard CallStore.shared.state != .idle else { return nil }
            let peer = CallStore.shared.current.remoteYxAccid
            return peer.isEmpty ? nil : peer
        }()
        await performIdleCleanupWithProtection(activeCallPeerId: activeCallPeerId)
    }
}
