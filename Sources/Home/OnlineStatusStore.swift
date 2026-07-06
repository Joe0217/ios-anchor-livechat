import Foundation
import SwiftUI
import Combine
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "online-status")

/// 主播首页顶部状态点 + Work 悬浮开关的共享 store。
///
/// **对齐安卓 3 态**（H5 只有 2 态；iOS 完整对齐安卓）：
/// - `.online`     🟢 WSHeartbeat connected + 未强制忙碌
/// - `.offline`    🔘 WSHeartbeat 断开 or 用户手动下线
/// - `.forcedBusy` 🔴 服务端强制设为忙碌（今日通话次数达上限）
///
/// **状态源**（关键：与用户端"看到主播在线"的信源保持一致）：
/// - `wsConnected` = **WSHeartbeat.connected**（api.seain.site/webSocket 心跳；用户端在线列表的唯一驱动）
/// - `forcedBusy`  = hasExceededCallLimit API 返回 isLimitMet=="1"（本地内存缓存）
/// - `userSetOnline` = Work 页悬浮开关（用户手动下线时置 false）
///
/// **不追 NIM 长连状态**：NIM 是 IM 消息通道，不决定"用户端能否看到主播在线"。
/// 圆点应与用户端感知一致 → 只跟 WSHeartbeat。
///
/// **`derivedDot` 派生优先级**（对齐安卓 `AppCache.isForcedBusy` 强制显示红）：
/// forcedBusy 最高 → 用户手动下线次之 → WS 状态兜底
///
/// **触发点**（对齐安卓 3 处）：
/// 1. 点刷新 `refreshOnline()` → checkForcedBusy(showToast=true, doAction=true)
/// 2. 收到 attachType=37 → checkForcedBusy(showToast=false, doAction=true)（SystemMessageRouter 转发）
/// 3. scenePhase → .active（"onResume"）→ checkForcedBusy(showToast=false, doAction=false)
@MainActor
final class OnlineStatusStore: ObservableObject {
    static let shared = OnlineStatusStore()

    // MARK: - 状态源

    /// 用户手动希望的在线态（Work 悬浮开关写）。默认 true（进入即在线，用户明确要求 2026-07-02）。
    @Published private(set) var userSetOnline: Bool = true

    /// 服务端强制忙碌（hasExceededCallLimit 返回 isLimitMet=="1"）。内存缓存，不持久化。
    /// 每次 checkForcedBusy 覆盖；无自动过期机制（对齐安卓 `AppCache.isForcedBusy`）。
    @Published private(set) var forcedBusy: Bool = false

    /// IM 长连状态（订阅 NIMService.connectionState）。
    @Published private(set) var wsConnected: Bool = false

    // MARK: - UI 派生态

    /// 顶部圆点最终颜色。
    var derivedDot: DotStatus {
        if forcedBusy { return .forcedBusy }
        if !userSetOnline { return .offline }
        return wsConnected ? .online : .offline
    }

    /// Work 悬浮开关显示态。forcedBusy 时视觉上仍 online（安卓端红点已在 Home 顶部提示）。
    var isOnline: Bool {
        derivedDot == .online || forcedBusy
    }

    // MARK: - 副作用态（UI 消费）

    /// 刷新按钮旋转动画中（对齐 H5 showRefreshAnimation）。
    @Published var isRefreshing: Bool = false

    /// 刷新完成 tick —— 值变化触发订阅方展示 reconnect toast。
    @Published var refreshToastTick: UUID?

    /// SetToBusyDialog 展示态（对齐安卓 SetToBusyDialog）。true 时 LiveTabView overlay 弹窗。
    @Published var showSetToBusyDialog: Bool = false

    // MARK: - 私有

    private var cancellables = Set<AnyCancellable>()

    /// 3 入口共享的 checkForcedBusy 串行化 slot（refreshOnline / triggerCheckForcedBusy 都用）。
    /// 命名沿革：refreshTask → activeCheckTask（审查报告-202607061550 必修-2）。
    private var activeCheckTask: Task<Void, Never>?

    private init() {
        // 初始兜底：直读 WSHeartbeat 当前 connected 值
        wsConnected = WSHeartbeat.shared.connected

        // 主路径：订阅 WSHeartbeat.$connected 变化 → wsConnected 派生（毫秒级实时）
        // WSHeartbeat 的 URLSession WebSocket delegate 事件（didOpen/didClose/socketErr/scheduleReconnect）
        // 都同步到 @Published connected —— 网络断/重连立即触发 sink。
        WSHeartbeat.shared.$connected
            .removeDuplicates()
            .sink { [weak self] connected in
                self?.wsConnected = connected
                logger.debug("[OnlineStatus] wsConnected sink → \(connected, privacy: .public)")
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Work 悬浮开关手动切换在线。false 触发时通常先弹确认（Work 层管弹窗），确认后调本方法。
    ///
    /// **立即 WS 上报**：不等下一次 15s ping tick，让服务端 <1s 感知新态；
    /// 否则最坏 15s 窗口内新的 P2P 呼叫仍派发给已下线主播。
    func setUserSetOnline(_ value: Bool) {
        userSetOnline = value
        WSHeartbeat.shared.reportManualOnlineStatus(isOnline: value)
    }

    /// 点刷新按钮：对齐安卓 queryHideState(showToast=true, doAction=true)：
    /// 1. 立即显示旋转 1s（`isRefreshing`）
    /// 2. 调 hasExceededCallLimit API
    /// 3. 未超限 → 用户置回上线（`setUserSetOnline(true)`）+ 触发 reconnect toast
    /// 4. 超限 → 弹 SetToBusyDialog（不触发 toast）
    func refreshOnline() {
        isRefreshing = true
        activeCheckTask?.cancel()
        activeCheckTask = Task { [weak self] in
            // 1s 旋转（不阻塞查询，两者并行）
            async let spin: () = Task.sleep(nanoseconds: 1_000_000_000)
            // 并行调 API + 消费 1s spin
            await self?.checkForcedBusy(showToast: true, doAction: true)
            _ = try? await spin
            // 双击竞态守卫：老 Task 被 cancel 后 try? 吞掉 CancellationError 继续跑到这里，
            // 若无此守卫 self.isRefreshing = false 会覆盖新 Task 已置的 true，动画闪断。
            // 复查报告-202607031135 必修-1。
            guard let self, !Task.isCancelled else { return }
            self.isRefreshing = false
        }
    }

    /// scenePhase → .active / attachType=37 静默检查入口。
    /// 与 refreshOnline 共享 `activeCheckTask` slot 保证 3 入口串行化——
    /// 否则短时间叠加时后到 API 返回会覆盖先到的 @Published 写入（forcedBusy / userSetOnline / refreshToastTick / showSetToBusyDialog）。
    ///
    /// **isRefreshing 中跳过**：refresh UI 反馈优先，避免用户点刷新时静默检查中途接管
    /// 让旋转动画卡死；refresh 自身会调 checkForcedBusy 反映最新态，业务结果最终一致。
    /// 审查报告-202607061550 必修-2。
    func triggerCheckForcedBusy(showToast: Bool, doAction: Bool) {
        guard !isRefreshing else {
            logger.debug("[OnlineStatus] triggerCheckForcedBusy skipped: isRefreshing=true")
            return
        }
        activeCheckTask?.cancel()
        activeCheckTask = Task { [weak self] in
            await self?.checkForcedBusy(showToast: showToast, doAction: doAction)
        }
    }

    /// 登出/切账号显式清空（`SessionStore.logout` 调）。
    /// **不清** `wsConnected` —— 依赖 `WSHeartbeat.stop` 触发 `$connected` sink 自动置 false，
    /// 避免手动重置后 sink 又覆盖回来的时序冲突。
    /// **不清** `cancellables` —— WSHeartbeat.$connected 订阅是跨账号常驻，登出后仍需 sink 更新 wsConnected。
    func clear() {
        activeCheckTask?.cancel()
        activeCheckTask = nil
        userSetOnline = true          // 恢复默认（"新账号进入即在线"，2026-07-02 产品要求）
        forcedBusy = false
        isRefreshing = false
        refreshToastTick = nil
        showSetToBusyDialog = false
        logger.info("[OnlineStatus] cleared (logout/switch account)")
    }

    /// 查 hasExceededCallLimit API 并按结果分支处理。
    /// - Parameters:
    ///   - showToast: 未超限时是否显示 reconnect toast（点刷新才 true）
    ///   - doAction: 未超限时是否触发"重连行为"（点刷新 / 收到 37 时 true；onResume 静默检查 false)
    ///
    /// **取消守卫**（必修-1 同款审视）：API 返回后所有 @Published 赋值前统一 checkCancellation，
    /// 避免老 Task 的迟到结果覆盖新 Task 已经更新的状态。
    func checkForcedBusy(showToast: Bool, doAction: Bool) async {
        do {
            let data = try await APIClient.shared.post("/api/anchor/hasExceededCallLimit", body: [:])
            // API 返回后立即自检取消：老 Task 网络请求慢 + 用户双击时，此处丢弃老 Task 结果
            if Task.isCancelled { return }

            let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let isLimitMet: String = {
                if let s = dict?["isLimitMet"] as? String { return s }
                if let n = dict?["isLimitMet"] as? NSNumber { return n.stringValue }
                return "0"
            }()
            let limited = (isLimitMet == "1")

            forcedBusy = limited

            if limited {
                showSetToBusyDialog = true
                logger.info("[OnlineStatus] forcedBusy=true — SetToBusyDialog will show")
            } else if doAction {
                // 未超限 + 允许 action：对齐安卓刷新按钮 3 件事：
                // 1) 用户置回上线（走 setUserSetOnline 触发 WSHeartbeat.reportManualOnlineStatus
                //    立即上报 .callEnd，覆盖 Work 页下线时残留的 .offline currentStatus。
                //    ❌ 不能直接 `userSetOnline = true`——那样会绕过 setter 里的 WS 上报，
                //    服务端持续收到 .offline 心跳，用户端仍看不到主播在线。
                setUserSetOnline(true)

                guard let user = SessionStore.shared.user else {
                    logger.notice("[OnlineStatus] refresh skip reconnect: no user")
                    if showToast { refreshToastTick = UUID() }
                    return
                }

                // 2) 触发 WSHeartbeat 重连（用户端"看到主播在线"的唯一驱动）
                //    stop+start 组合立即重连，不等内部 5s scheduleReconnect tick
                if let uuid = user.loginUuid, !uuid.isEmpty, !WSHeartbeat.shared.connected {
                    logger.info("[OnlineStatus] WSHeartbeat 断开，触发重连")
                    WSHeartbeat.shared.stop()
                    WSHeartbeat.shared.start(loginUuid: uuid)
                }

                // 3) 触发 NIM 长连（IM 消息通道，对齐安卓"发布 NIM 前台事件"）
                //    幂等：NIMOnlineKeeper.start 内部守 isLogined。首次点刷新时若 NIM 未登录 → 补触发。
                if let account = user.yxAccid, !account.isEmpty,
                   let token = user.imToken, !token.isEmpty {
                    NIMOnlineKeeper.shared.start(account: account, token: token)
                }

                // 4) 从 WSHeartbeat 直读兜底同步 wsConnected（重连未完成前先反映当前实态）
                wsConnected = WSHeartbeat.shared.connected
                if showToast {
                    refreshToastTick = UUID()
                }
            }
        } catch {
            logger.error("[OnlineStatus] hasExceededCallLimit failed: \(String(describing: error), privacy: .public)")
            // 查询失败 → 不覆盖 forcedBusy（保留上次值），不弹窗
        }
    }
}

// MARK: - 圆点状态

/// 顶部圆点 3 态。
enum DotStatus: Equatable {
    case online       // 🟢
    case offline      // 🔘
    case forcedBusy   // 🔴
}
