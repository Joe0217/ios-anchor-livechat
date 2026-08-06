import Foundation
import Combine

extension SelfPermissionBridge {
    /// 全项目单例。
    ///
    /// **实现说明**（回应真机编译错 · SessionStore 是 @MainActor 而 static let init closure 是 nonisolated 上下文）：
    /// 用 relay `CurrentValueSubject` 做中转 —— init closure 不直接读 `SessionStore.$user`（跨 actor 编译错），
    /// 通过 `Task { @MainActor }` 异步绑定。启动瞬间 Task 立即调度到 main runloop，UI 层订阅 `isLoaded == false`
    /// 期间 deny-by-default 兜底（对齐 spec §6.1）。
    ///
    /// **不入 HilyTests 白名单**：SessionStore 有 Networking / SDK 依赖；单测走 `init(sessionPublisher:)` 注 fake。
    static let shared: SelfPermissionBridge = makeShared()

    /// nonisolated 静态工厂：创建会话状态 relay + Bridge，异步 Task 里绑定 SessionStore（避免直接跨 actor 读 @MainActor 属性）。
    private static func makeShared() -> SelfPermissionBridge {
        let sessionRelay = CurrentValueSubject<PermissionSessionState, Never>(.loggedOut)

        let bridge = SelfPermissionBridge(
            sessionPublisher: sessionRelay.eraseToAnyPublisher()
        )

        // 异步派发到 MainActor 绑定登录态。当前包固定为 107，不读取真实 userType，
        // DEBUG override 同样不再改变有效角色，避免提审结构被本地状态漂移。
        Task { @MainActor in
            let session = SessionStore.shared
            session.$user
                .sink { user in
                    let isAuthenticated = user != nil
                    sessionRelay.send(PermissionSessionState(
                        userType: UserTypeExperience.effectiveUserType(isAuthenticated: isAuthenticated),
                        isAuthenticated: isAuthenticated
                    ))
                }
                .store(in: &sharedBindCancellables)
        }

        return bridge
    }

    /// Session 绑定持有的 cancellables（static 生命周期与 shared 同 · 只在启动时写一次，后续无 concurrent access）。
    /// nonisolated(unsafe)：Task @MainActor 内 `store(in:)` 是 main actor 写；后续 shared 生命周期无跨 actor 改动。
    private nonisolated(unsafe) static var sharedBindCancellables = Set<AnyCancellable>()
}
