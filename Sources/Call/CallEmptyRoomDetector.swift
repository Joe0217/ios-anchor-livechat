import Foundation
import os

/// 黑屏空房间检测状态机（DM-20260616-003，对齐 H5 `useEmptyRoomDetector.js` + 安卓 EmptyRoomDetector）。
///
/// **回归修复关键**：iOS 主播端此前完全未实现此检测 → 服务端认为主播端异常 →
/// 用户端 EmptyRoomDetector 连续 3 次 `isNormal=false` → 弹 10s 倒计时 → 5min 自动 hangup
/// （用户实测两次私 call 均在 299s 收到 RTM Hangup 复现此路径）。
///
/// **行为**：
/// - 接通后每 10s 调 `POST /api/agora/live/channelUserCount { channelId }` 心跳查询通话是否正常
/// - 连续 3 次 `isNormal=false` → 弹 10s 倒计时弹窗，走满触发自动挂断
/// - 任意一次 `isNormal=true` → 清零 + 关弹窗 + **永久停止后续轮询**（H5 stopped 语义）
/// - 请求失败 / 网络异常 → 清零，避免误挂断（但不停止轮询）
/// - 状态机不自持 10s 定时器，由 `CallStore.startElapsedTask` 每秒 tick 时按 elapsed % 10 == 0 驱动
@MainActor
final class CallEmptyRoomDetector: ObservableObject {
    /// 心跳周期秒数（对齐 H5 topBar.vue CCalculagraph tenSecondsCB / 安卓 10s tick）
    static let tickInterval = 10
    /// 连续第 N 次异常弹倒计时弹窗（对齐 H5 EMPTY_ROOM_DIALOG_COUNT）
    static let dialogThreshold = 3
    /// 倒计时弹窗时长（对齐 H5 emptyRoomCountdownPop.vue COUNTDOWN_SECONDS=10）
    static let countdownSeconds = 10

    /// UI 观察：非 nil 时展示倒计时弹窗。CallStore 通过 closure 回写把它转发到 @Published 供 CallView 消费
    @Published private(set) var countdownRemaining: Int?

    private var abnormalCount = 0
    private var stopped = false
    private var hungUp = false
    private var lastVoJson: String = ""
    private var countdownTask: Task<Void, Never>?

    /// 取当前通话 channelId；nil 时 skip tick
    private let getChannelId: () -> String?
    /// 与 RTC 本地异常框互斥（对齐 H5 canShowPopup）；返回 false 时抑制本轮弹窗
    private let canShowPopup: () -> Bool
    /// 倒计时归零触发的挂断回调（透传最近一次 vo json 供埋点）
    private let onHangup: (String) -> Void
    /// 埋点回调：状态 = "showCountdown" | "recovered" | "autoHangup"
    private let onReport: (String) -> Void

    init(getChannelId: @escaping () -> String?,
         canShowPopup: @escaping () -> Bool = { true },
         onHangup: @escaping (String) -> Void,
         onReport: @escaping (String) -> Void = { _ in }) {
        self.getChannelId = getChannelId
        self.canShowPopup = canShowPopup
        self.onHangup = onHangup
        self.onReport = onReport
    }

    /// 心跳 tick（由外部每 10s 调用一次）。对齐 H5 useEmptyRoomDetector.tick()
    func tick() async {
        AppLogger.call.notice("🩺 [EmptyRoom] tick start stopped=\(self.stopped, privacy: .public) hungUp=\(self.hungUp, privacy: .public) abnormalCount=\(self.abnormalCount, privacy: .public)")
        guard !stopped, !hungUp else {
            AppLogger.call.notice("🩺 [EmptyRoom] tick SKIP (stopped=\(self.stopped, privacy: .public) hungUp=\(self.hungUp, privacy: .public))")
            return
        }
        guard let channelId = getChannelId(), !channelId.isEmpty else {
            AppLogger.call.notice("🩺 [EmptyRoom] tick SKIP (channelId nil/empty)")
            return
        }

        AppLogger.call.notice("🩺 [EmptyRoom] tick → calling channelUserCount channelId=\(channelId, privacy: .public)")
        let res = await CallService.channelUserCount(channelId: channelId)

        // await 期间通话已切换/结束/停止 → 丢弃本次结果（对齐 H5 channelId 校验 + stopped/hungUp 判断）
        guard !stopped, !hungUp, getChannelId() == channelId else {
            AppLogger.call.notice("🩺 [EmptyRoom] tick DROP result (await 期间 stopped/hungUp/channel 切换)")
            return
        }

        guard let res else {
            // 请求失败/网络异常不计为异常，清零以避免误挂断（对齐 H5 catch 分支）
            abnormalCount = 0
            dismissCountdown()
            AppLogger.call.notice("🩺 [EmptyRoom] tick → res=nil (API 失败/网络异常) 清零")
            return
        }

        // 记录本次响应 json，供后续自动挂断埋点使用
        if let data = try? JSONEncoder().encode(res),
           let json = String(data: data, encoding: .utf8) {
            lastVoJson = json
        }

        // 通话正常：清零、关弹窗，并永久停止后续轮询
        if res.isNormal == true {
            abnormalCount = 0
            dismissCountdown()
            stopped = true
            AppLogger.call.notice("🩺 [EmptyRoom] tick → isNormal=true → stopped (once-normal-forever)")
            return
        }

        // 空房间异常（isNormal == false）
        // 弹窗已展示：挂断仅由倒计时驱动，不再按次数累计
        if countdownRemaining != nil {
            AppLogger.call.notice("🩺 [EmptyRoom] tick → isNormal=false 但倒计时展示中，跳过累加")
            return
        }

        abnormalCount += 1
        AppLogger.call.notice("🚨 [EmptyRoom] tick → isNormal=false abnormalCount=\(self.abnormalCount, privacy: .public) threshold=\(Self.dialogThreshold, privacy: .public)")
        if abnormalCount >= Self.dialogThreshold {
            // 与 RTC 本地异常框互斥：本地异常框展示中则本轮抑制，下一异常拍再弹（计数已累加）
            guard canShowPopup() else {
                AppLogger.call.notice("🩺 [EmptyRoom] canShowPopup=false 抑制本轮弹窗")
                return
            }
            startCountdown()
        }
    }

    /// 房间恢复 / 通话切换时关闭倒计时弹窗（对齐 H5 dismiss）
    func dismissCountdown() {
        guard countdownRemaining != nil else { return }
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemaining = nil
        onReport("recovered")
    }

    /// 启动 10s 倒计时（不可取消，走满自动挂断）。对齐 H5 emptyRoomCountdownPop.vue
    private func startCountdown() {
        AppLogger.call.notice("🚨 [EmptyRoom] 连续 \(Self.dialogThreshold, privacy: .public) 次异常 → 弹 \(Self.countdownSeconds, privacy: .public)s 倒计时")
        countdownRemaining = Self.countdownSeconds
        onReport("showCountdown")
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            for _ in 0..<Self.countdownSeconds {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self, let remain = self.countdownRemaining else { return }
                    if remain > 1 {
                        self.countdownRemaining = remain - 1
                    }
                    // 保留显示 1 避免闪 0（对齐 H5 remain.value <= 1 分支）
                }
            }
            await MainActor.run { self?.triggerHangup() }
        }
    }

    /// 倒计时归零触发自动挂断（幂等）。对齐 H5 triggerHangup
    func triggerHangup() {
        guard !hungUp else { return }
        hungUp = true
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemaining = nil
        onReport("autoHangup")
        AppLogger.call.notice("🚨 [EmptyRoom] 倒计时归零 → 自动挂断 msg=\(self.lastVoJson, privacy: .private)")
        onHangup(lastVoJson)
    }

    /// 通话结束 / 组件卸载时清空全部状态。对齐 H5 reset
    func reset() {
        abnormalCount = 0
        stopped = false
        hungUp = false
        lastVoJson = ""
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemaining = nil
    }
}
