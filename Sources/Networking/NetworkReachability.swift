import Foundation
import Network
import Combine
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "NetworkReachability")

/// 全局网络可达性 gate。
///
/// **解决问题**：iOS 首次安装（尤其中国区）会弹「允许使用无线数据」权限对话框。
/// 用户点允许前，`URLSession` 请求会立即失败（URLError.notConnectedToInternet 等）。
/// 冷启动首屏触发的多个请求（AnchorInfoStore / AppPictureStore / GiftMarqueeStore ...）
/// 会全部 fail，UI 显示「Network error」——真实原因是权限尚未授予。
///
/// **机制**：`NWPathMonitor` 首次回调 `.satisfied` 前，`waitUntilReachable` 阻塞请求。
/// 用户点允许后 path 立即变 `.satisfied`，唤醒所有等待中的请求。
///
/// **超时兜底**（默认 10s）：monitor 异常或真的无网络时不会永远卡死——超时后放行
/// 走原错误路径，业务侧仍能感知失败、显示错误 UI，行为与未加 gate 一致。
///
/// **并发精确**：每个 waiter 独立 UUID 追踪，单个 waiter 超时不会误唤醒其他 waiter。
/// 首次 `.satisfied` 边沿一次性唤醒所有 waiter，`.unsatisfied` 不影响已挂起的等待。
@MainActor
final class NetworkReachability {
    static let shared = NetworkReachability()

    /// 当前网络是否可达（`NWPathMonitor` 观察）。
    /// - `nil`：monitor 首次回调之前的未知态
    /// - `true` / `false`：首次回调之后的实际态
    ///
    /// UI 层可订阅本属性（objectWillChange）反应式感知网络恢复；本次仅网络层用作 gate。
    @Published private(set) var isReachable: Bool?

    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "com.anchor.livechat.reachability", qos: .userInitiated)

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
        /// 关联的超时 Task。上升沿唤醒时 cancel,避免 waiter 已 resume 后 Task 仍 sleep 满 10s 空跑。
        var timeoutTask: Task<Void, Never>?
    }
    private var waiters: [Waiter] = []

    private init() {
        monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = (path.status == .satisfied)
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(satisfied: satisfied)
            }
        }
        monitor.start(queue: monitorQueue)
        logger.debug("NetworkReachability monitor started")
    }

    /// 等待网络可达。已可达立即返回；否则阻塞至首次 `.satisfied` 边沿或 `timeout` 超时。
    ///
    /// 超时后返回不代表网络可用——请求会继续走并 fail，业务侧仍能进错误路径。
    func waitUntilReachable(timeout: TimeInterval = 10) async {
        if isReachable == true { return }
        let id = UUID()
        await withCheckedContinuation { cont in
            // 精确超时：单个 waiter 一到点仅 resume 自己那一格；其他 waiter 不受影响。
            // 上升沿唤醒时 handlePathUpdate 会 cancel 该 task → sleep 抛 CancellationError → 跳过 timeoutWaiter，
            // 避免 waiter 已 resume 后 Task 空 sleep 满 10s（review 202607062237 N-1 修复）。
            let timeoutTask = Task { [weak self] in
                guard (try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))) != nil else {
                    return
                }
                await self?.timeoutWaiter(id: id)
            }
            waiters.append(Waiter(id: id, continuation: cont, timeoutTask: timeoutTask))
        }
    }

    private func handlePathUpdate(satisfied: Bool) {
        let previous = isReachable
        isReachable = satisfied
        // 只在 nil / false → true 的上升沿唤醒。true → true / *→false 都不动 waiter。
        guard previous != true, satisfied else { return }
        let snapshot = waiters
        waiters.removeAll()
        logger.debug("path became satisfied, resuming \(snapshot.count, privacy: .public) waiter(s)")
        for w in snapshot {
            w.timeoutTask?.cancel()
            w.continuation.resume()
        }
    }

    private func timeoutWaiter(id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        let w = waiters.remove(at: idx)
        logger.debug("waiter \(id.uuidString.prefix(8), privacy: .public) timed out; resuming for original error path")
        w.continuation.resume()
    }
}
