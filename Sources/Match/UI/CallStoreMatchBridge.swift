import Combine
import Foundation

/// U3：CallStore ↔ MatchStore 观察桥接（`MatchCallStoreObserving` 具体实现）。
///
/// **为什么在 UI/ 层**：本 bridge 引 `CallStore.shared` 具体类型 —— MatchStore 定义在 test target sources，
/// 引 CallStore 会破坏 test module 隔离。UI/ 目录不入 test target，可自由引具体单例。
///
/// **挂载**：App 启动路径（HilyApp / RootView 入口）调 `MatchStore.shared.attachCallStoreBridge(bridge)`
/// 完成 wiring。生命周期与 App 一致（单例 owner）。
@MainActor
final class CallStoreMatchBridge: MatchCallStoreObserving {

    static let shared = CallStoreMatchBridge()

    private let callStore = CallStore.shared

    /// 快照 CallStore.lastJoinCallSource 供 idle 恢复判定读取
    var latestJoinCallSource: String? {
        callStore.lastJoinCallSource
    }

    /// P2-1 对齐 H5 useCallApi.js:397：上一次通话是否为异常出错结束。
    /// 判定 = `current.hangupReason == .beginCallError`（RTC/RTM/信令建链失败对应 CallOverReason 10）。
    /// MatchStore 在 .matchingCalling → .idle 时读此值走"关匹配"分支。
    var latestHangupWasError: Bool {
        callStore.current.hangupReason == .beginCallError
    }

    // MARK: - Publishers（对齐 MatchCallStoreObserving protocol）

    /// state.$state 到 .calling/.connecting/.connected 触发 —— MatchStore 用来在通话中间态无条件 unsubscribe camera
    var stateChangePublisher: AnyPublisher<Bool, Never> {
        callStore.$state
            .map { $0 == .calling || $0 == .connecting || $0 == .connected }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// CallStore.$lastJoinCallSource 直接透传
    var lastJoinCallSourcePublisher: AnyPublisher<String?, Never> {
        callStore.$lastJoinCallSource.eraseToAnyPublisher()
    }

    /// CallStore.state → .idle 边（`.connected → .ended → .idle` 通话完全结束后）
    var stateReturnedToIdlePublisher: AnyPublisher<Void, Never> {
        callStore.$state
            .removeDuplicates()
            .compactMap { state -> Void? in
                state == .idle ? () : nil
            }
            .dropFirst()  // 跳过冷启动 .idle 初始值（不算"回到 idle"）
            .eraseToAnyPublisher()
    }

    /// Gap-5：CallStore.state 进入 .connected 的边（每次接通触发一次）
    var enteredConnectedPublisher: AnyPublisher<Void, Never> {
        callStore.$state
            .removeDuplicates()
            .compactMap { state -> Void? in
                state == .connected ? () : nil
            }
            .eraseToAnyPublisher()
    }

    private init() {}
}
