import Foundation
import UIKit
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "HeartbeatController")

/// 直播心跳控制器（B 里程碑 spec §3）。
///
/// 10s 间隔（对齐安卓；H5 6s 与 "10秒" 注释均废弃）。
/// 连续失败 >3 次 → store.forceEnd(.disconnected, subSource: "heartbeat_failed") → endType=4。
/// 响应码分流：1992/1006 → .banned (endType=2)；2001 → .noPermission (endType=6)。
///
/// **v5.3.2 修复**：tick 内 guard `UIApplication.shared.applicationState != .background`：
/// - 后台时 main thread 挂起，本来 tick 也跑不了，但 Task.sleep 完成后 backlog tick 可能一次性串行跑
/// - 后台时进行的 heartbeat API 调用可能因 URLSession 后台挂起 timeout 失败，回前台后批量计 failure
/// - 双保险：后台 tick 直接 return 不调 API + 不计 failure
@MainActor
final class HeartbeatController {
    private weak var store: LiveStore?
    private var task: Task<Void, Never>?
    private var failureCount: Int = 0

    init(store: LiveStore) {
        self.store = store
    }

    /// LiveStore 进入 .living 态时调用。重复 start 会先 stop 再 start。
    func start() {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                // 10s 间隔（spec §3.1）
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    /// teardown 时调用：取消 Task + 重置失败计数。
    func stop() {
        task?.cancel()
        task = nil
        failureCount = 0
    }

    private func tick() async {
        // v5.3.2：app 在 background 时静默跳过，避免回前台后 backlog 批量计 failure 触发 endType=4
        guard UIApplication.shared.applicationState != .background else {
            logger.info("heartbeat tick skipped: app in background")
            return
        }
        guard let store, let roomId = store.roomId else { return }
        do {
            try await LiveService.heartbeat(roomId: roomId, callState: store.callState)
            failureCount = 0
        } catch HeartbeatError.banned {
            await store.forceEnd(reason: .banned, subSource: "heartbeat_1992")
        } catch HeartbeatError.noPermission {
            await store.forceEnd(reason: .noPermission, subSource: "heartbeat_2001")
        } catch {
            failureCount += 1
            let count = failureCount
            logger.warning("heartbeat failed (\(count)/3): \(String(describing: error))")
            if count > 3 {
                await store.forceEnd(reason: .disconnected, subSource: "heartbeat_failed")
            }
        }
    }
}
