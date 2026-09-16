import AgoraRtcKit
import UIKit
import os

private let logger = Logger(subsystem: "com.hilly.anchor", category: "PK")

/// G 里程碑 M0：PK 频道独立 delegate。
///
/// 直播主频道（`AgoraManager` 本身）与 PK 对手频道（每条 PK 一个独立 `AgoraRtcConnection`）共享
/// 同一 `AgoraRtcEngineKit` singleton，但回调必须区分来源——主频道回调走 `AgoraManager`，
/// PK 频道回调走本 delegate，避免 `didJoinedOfUid` 撞主频道 `remoteView`、`didOfflineOfUid` 误清主频道 `remoteUid`。
///
/// 关键点：
/// - `owner` 弱引用 `AgoraManager`，避免循环；engine reuse 时主延迟由 owner 控制
/// - `oppositeView` 弱引用对手画面渲染目标（由 PKArenaView 持有，M3 接入）；M0 阶段为 nil 仅测试 join 通路
/// - `didJoinedOfUid` 只挑期望的 `oppositeUid`，过滤主频道串入（极端竞态时 SDK 可能短时给错频道事件）
/// - `didLeaveChannelWith` 在多频道场景下被 SDK 改派为 `didLeaveChannelExWith`（4.x SDK 头文件确认）；
///   两个回调都收，由 owner 按 channel 维度 resume 对应的 `leavePKContinuations[channel]`
final class PKChannelDelegate: NSObject, AgoraRtcEngineDelegate {
    private let analyticsLock = NSLock()
    private var didReportLeave = false

    private func reportLeave(duration: UInt) {
        analyticsLock.lock()
        guard !didReportLeave else { analyticsLock.unlock(); return }
        didReportLeave = true
        analyticsLock.unlock()
        AnalyticsTracker.trackAgora("pk_local_left", scene: "pk", properties: ["channel_id": channel, "duration": duration])
    }
    weak var owner: AgoraManager?
    let channel: String
    let oppositeUid: UInt
    /// 对手画面渲染目标（M3 PKArenaView 注入；M0 阶段保持 nil，仅验证 join 通路）
    weak var oppositeView: UIView?

    init(owner: AgoraManager, channel: String, oppositeUid: UInt) {
        self.owner = owner
        self.channel = channel
        self.oppositeUid = oppositeUid
        super.init()
    }

    // MARK: - 远端事件（仅响应本 PK 频道）
    func rtcEngine(_ engine: AgoraRtcEngineKit, connectionChangedTo state: AgoraConnectionState, reason: AgoraConnectionChangedReason) {
        AnalyticsTracker.trackAgora("agora_connection_state", scene: "pk", properties: ["channel_id": channel, "state": state.rawValue, "reason": reason.rawValue])
    }


    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinedOfUid uid: UInt, elapsed: Int) {
        // 多频道场景 SDK 不直接告知 channel 归属，仅靠期望 uid 过滤
        guard uid == oppositeUid else { return }
        logger.info("PK remote joined channel=\(self.channel) uid=\(uid) elapsed=\(elapsed)ms")
        AnalyticsTracker.trackAgora("pk_remote_joined", scene: "pk", properties: ["channel_id": channel, "remote_uid": uid])
        DispatchQueue.main.async { [weak self] in
            guard let self, let owner = self.owner else { return }
            guard let conn = owner.pkConnection(forChannel: self.channel) else {
                logger.warning("PK didJoinedOfUid but connection gone channel=\(self.channel)")
                return
            }
            guard let view = self.oppositeView else { return }  // M0 阶段 view 未注入则跳过 setup
            let canvas = AgoraRtcVideoCanvas()
            canvas.uid = uid
            canvas.view = view
            canvas.renderMode = .hidden
            engine.setupRemoteVideoEx(canvas, connection: conn)
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOfflineOfUid uid: UInt, reason: AgoraUserOfflineReason) {
        guard uid == oppositeUid else { return }
        logger.info("PK remote offline channel=\(self.channel) uid=\(uid) reason=\(reason.rawValue)")
        AnalyticsTracker.trackAgora("pk_remote_left", scene: "pk", properties: ["channel_id": channel, "remote_uid": uid, "reason": reason.rawValue])
        DispatchQueue.main.async { [weak self] in
            guard let self, let owner = self.owner else { return }
            guard let conn = owner.pkConnection(forChannel: self.channel) else { return }
            let canvas = AgoraRtcVideoCanvas()
            canvas.uid = uid
            canvas.view = nil
            engine.setupRemoteVideoEx(canvas, connection: conn)
        }
    }

    /// 多频道 leave 回调（4.x SDK 名 didLeaveChannelExWith；若 SDK 头文件实际签名不同需 M0 编译期暴露）
    func rtcEngine(_ engine: AgoraRtcEngineKit,
                   didLeaveChannelExWith stats: AgoraChannelStats,
                   channelId: String,
                   localUid: UInt) {
        guard channelId == channel else { return }
        logger.info("PK leftEx channel=\(channelId) duration=\(stats.duration)s")
        reportLeave(duration: stats.duration)
        owner?.resumeLeavePKContinuation(channel: channelId)
    }

    /// 兜底：若 SDK 走单频道 didLeaveChannelWith 回调（多 connection 旧版本/边界场景），按本 delegate 的 channel resume
    func rtcEngine(_ engine: AgoraRtcEngineKit, didLeaveChannelWith stats: AgoraChannelStats) {
        logger.info("PK leftFallback channel=\(self.channel) duration=\(stats.duration)s")
        reportLeave(duration: stats.duration)
        owner?.resumeLeavePKContinuation(channel: channel)
    }

    // MARK: - 错误
    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinChannel channel: String, withUid uid: UInt, elapsed: Int) {
        AnalyticsTracker.trackAgora("pk_local_joined", scene: "pk", properties: ["channel_id": channel, "elapsed_ms": elapsed])
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, firstRemoteAudioFrameOfUid uid: UInt, elapsed: Int) {
        AnalyticsTracker.trackAgora("agora_remote_audio_received", scene: "pk", properties: ["channel_id": channel, "remote_uid": uid, "elapsed_ms": elapsed])
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, firstRemoteVideoFrameOfUid uid: UInt, size: CGSize, elapsed: Int) {
        AnalyticsTracker.trackAgora("agora_remote_video_rendered", scene: "pk", properties: ["channel_id": channel, "remote_uid": uid, "elapsed_ms": elapsed])
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) {
        AnalyticsTracker.trackAgora("agora_error", scene: "pk", properties: ["channel_id": channel, "error_code": errorCode.rawValue])
        logger.error("PK channel error channel=\(self.channel) code=\(errorCode.rawValue)")
        // M0 仅日志；token 续期 + 业务降级留 M2/M3 接入
    }
}
