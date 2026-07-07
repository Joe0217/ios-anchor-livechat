import Foundation

/// H-1 MVP：生产轨 shared 单例。
///
/// **三轨接线**（B 档降档合并 Step 2）：
/// - **真轨**：`MessageSessionStore.shared`（本文件）—— NIMSessionAdapter + PrimeLevelService.shared
/// - **Preview 轨**：`MessageListView_Previews.makeStore(...)` 用内联 Fake（不依赖 SDK）
/// - **Fakes 轨**：`FakeMessageSessionProvider` + `FakePrimeLevelProvider`（HilyTests 用）
///
/// **懒加载**：Swift `static let` 天然 thread-safe + lazy，首次访问时构造 Adapter；
/// MainTabView keep-alive 架构下 shared 生命周期与 app 一致（永久持有）。
extension MessageSessionStore {
    @MainActor
    static let shared: MessageSessionStore = {
        let store = MessageSessionStore(
            provider: NIMSessionAdapter(),
            primeProvider: PrimeLevelService.shared
        )
        // v5.5 空闲清理机制：shared 一被访问就完整挂上 AutoOfflineMonitor sink，
        // 避免遗漏 wiring 造成清理机制沉默失效
        store.attachAutoOfflineObserver()
        return store
    }()
}
