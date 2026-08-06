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
    /// 已创建的生产 Store。独立保存引用以便 SessionStore 在 107/登出时只同步既有实例，
    /// 不会为了执行权限收敛而提前构造 NIMSessionAdapter。
    @MainActor private static var initializedSharedStore: MessageSessionStore?

    @MainActor
    static let shared: MessageSessionStore = {
        let store = MessageSessionStore(
            provider: NIMSessionAdapter(),
            primeProvider: PrimeLevelService.shared
        )
        // shared 可能在登录后才被陈旧导航或未读 bridge 首次访问。
        // 创建当下立即套用权限，避免 107 的延迟实例以默认开启态拉取 P2P/Station。
        store.setDirectMessagesCapabilityEnabled(
            SelfPermissionBridge.shared.canDirectMessagesSnapshot
        )
        // v5.5 空闲清理机制：shared 一被访问就完整挂上 AutoOfflineMonitor sink，
        // 避免遗漏 wiring 造成清理机制沉默失效
        store.attachAutoOfflineObserver()
        initializedSharedStore = store
        return store
    }()

    /// 只更新已创建的 shared Store。107 冷启动没有消息入口时不得因本调用注册 P2P 会话 delegate。
    @MainActor
    static func updateSharedDirectMessagesCapability(isAllowed: Bool) {
        initializedSharedStore?.setDirectMessagesCapabilityEnabled(isAllowed)
    }
}
