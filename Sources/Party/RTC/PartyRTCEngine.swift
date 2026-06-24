import AgoraRtcKit
import CoreVideo
import Foundation
import UIKit

/// 派对房声网 RTC 封装（spec §1.4.3）。与直播 `AgoraManager` 并存，**不复用业务层**。
///
/// **抽取候选点（路线图 §五）**：底层 `AgoraRtcEngineKit.sharedEngine(with:)` 是**进程级单例**，
/// 与 `AgoraManager` 共享同一实例。三场景（直播 / 1v1 通话 / 派对房）切换必须严格：
/// 1. `join` 前显式 `setChannelProfile + setAudioScenario + setAudioProfile`
/// 2. `delegate = self` 显式重设（sharedEngine 复用会保留前一次的 delegate）
/// 3. `leave` 用 `CheckedContinuation` 等 `didLeaveChannelWith` 回调，**不调 `destroy()`**
///    （D v5.4 已踩坑：destroy 后立刻 sharedEngine join 会拿到半销毁实例）
///
/// 语聊场景配置（02-04 §3.2）：
/// - `channelProfile = .liveBroadcasting`（不是 .communication）
/// - `audioScenario = .chatRoom`
/// - `audioProfile = .speechStandard`
///
/// 默认进 `.audience` 观众；上麦切 `.broadcaster` + `enableLocalAudio(true)`；
/// 视频位额外 `enableLocalVideo(true)` + 接外部源订阅（M5 接 CameraManager v5.8 字典）。
///
/// 远端音频**禁止**用 `muteRemoteAudioStream`（订阅层取消，解禁后首帧丢失）；
/// 必须用 `adjustUserPlaybackSignalVolume(uid, 0/100)` 在播放端静音。
final class PartyRTCEngine: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case joining
        case joined
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var remoteUids: Set<UInt> = []
    /// 远端 uid → 当前播放音量（0/100）。视图层不直接消费；M5 视频位时复用作展示信号。
    @Published private(set) var remoteVolumes: [UInt: Int] = [:]

    weak var delegate: PartyRTCEngineDelegate?

    private var engine: AgoraRtcEngineKit?

    /// leave channel 异步等待句柄（D v5.4 模式）
    private var leaveContinuation: CheckedContinuation<Void, Never>?

    /// 视频位推帧是否已启用（默认 false，仅 `enableVideoSeat()` 后置 true）
    private(set) var videoSeatActive = false

    /// 当前在频道（state == .joined 衍生方便外部判定）
    var isActive: Bool { state == .joined || state == .joining }

    // MARK: - join

    /// 加入派对房语聊频道。默认观众角色 + 禁推视频；上麦时再切角色 / 启用视频源。
    @MainActor
    func join(channelId: String, token: String, uid: UInt) {
        guard engine == nil else {
            AppLogger.party.notice("[PartyRTC] already engaged, skip join")
            return
        }

        let config = AgoraRtcEngineConfig()
        config.appId = AgoraConfig.appId
        config.channelProfile = .liveBroadcasting
        let kit = AgoraRtcEngineKit.sharedEngine(with: config, delegate: self)
        // 进程级单例复用 → 显式重设 delegate + profile + audio scenario / profile
        kit.delegate = self
        kit.setChannelProfile(.liveBroadcasting)
        kit.setAudioScenario(.chatRoom)
        kit.setAudioProfile(.speechStandard)

        // 语聊默认禁视频（M5 视频位再 enableVideo）
        kit.disableVideo()
        kit.enableAudio()
        kit.setDefaultAudioRouteToSpeakerphone(true)
        kit.enableAudioVolumeIndication(500, smooth: 3, reportVad: false)

        engine = kit

        let option = AgoraRtcChannelMediaOptions()
        option.clientRoleType = .audience
        option.publishMicrophoneTrack = false
        option.publishCustomVideoTrack = false
        option.autoSubscribeAudio = true
        option.autoSubscribeVideo = true

        state = .joining
        AppLogger.party.info("[PartyRTC] joinChannel ch=\(channelId, privacy: .public) uid=\(uid, privacy: .public)")
        let ret = kit.joinChannel(byToken: token, channelId: channelId, uid: uid, mediaOptions: option)
        if ret != 0 {
            AppLogger.party.error("[PartyRTC] joinChannel failed ret=\(ret, privacy: .public)")
            state = .failed("joinChannel: \(ret)")
            delegate?.partyRTCEngine(self, didFailWithReason: "join_\(ret)")
        }
    }

    // MARK: - 上下麦

    /// 自己上麦：切 broadcaster + 启用本地音频。视频位额外 `enableLocalVideo` + 外部源（M5 在 PartyStore 接 CameraManager）。
    @MainActor
    func upperSeat(seatType: PartyRoomSeatType) {
        guard let engine else { return }
        engine.setClientRole(.broadcaster)
        engine.enableLocalAudio(true)

        let option = AgoraRtcChannelMediaOptions()
        option.clientRoleType = .broadcaster
        option.publishMicrophoneTrack = true
        // 视频位的 publishCustomVideoTrack 在 enableVideoSeat 内开
        option.publishCustomVideoTrack = (seatType == .video) ? true : false
        engine.updateChannel(with: option)
        AppLogger.party.info("[PartyRTC] upperSeat seatType=\(seatType.rawValue, privacy: .public)")
    }

    /// 自己下麦：切 audience + 关闭本地音频/视频。
    @MainActor
    func downSeat() {
        guard let engine else { return }
        engine.setClientRole(.audience)
        engine.enableLocalAudio(false)
        engine.enableLocalVideo(false)

        let option = AgoraRtcChannelMediaOptions()
        option.clientRoleType = .audience
        option.publishMicrophoneTrack = false
        option.publishCustomVideoTrack = false
        engine.updateChannel(with: option)

        if videoSeatActive {
            // 视频位下麦时同步取消外部源（M5 PartyStore 内 unsubscribe CameraManager）
            disableVideoSeatInternal()
        }
        AppLogger.party.info("[PartyRTC] downSeat")
    }

    /// 静音/取消静音他人（**播放端**，非订阅层）。
    /// volume 100=正常音量；0=静音。spec §1.2 决策——禁止 `muteRemoteAudioStream`。
    @MainActor
    func setRemoteAudio(uid: UInt, enabled: Bool) {
        guard let engine else { return }
        let vol: Int32 = enabled ? 100 : 0
        engine.adjustUserPlaybackSignalVolume(uid, volume: vol)
        remoteVolumes[uid] = Int(vol)
    }

    /// 自己麦克风开关（用户主动 mute）；与 setClientRole 解耦——下麦后不再调用。
    @MainActor
    func muteLocalMicrophone(_ muted: Bool) {
        engine?.muteLocalAudioStream(muted)
        AppLogger.party.info("[PartyRTC] muteLocalMic=\(muted, privacy: .public)")
    }

    // MARK: - 视频位（M5 完整实装；M2 仅占位接口让 PartyStore 编译过）

    /// 启用视频位推帧。本端帧由 PartyStore 接 CameraManager v5.8 订阅字典推到 `pushFrame`。
    /// MVP 编码档位固定 360×640 @ 15fps（spec §1.4.3 + §1.5 #12）。
    @MainActor
    func enableVideoSeat() {
        guard let engine else { return }
        guard !videoSeatActive else { return }
        engine.enableVideo()
        engine.setExternalVideoSource(true, useTexture: true, sourceType: .videoFrame)
        engine.setVideoEncoderConfiguration(
            AgoraVideoEncoderConfiguration(
                size: CGSize(width: 360, height: 640),
                frameRate: AgoraVideoFrameRate.fps15.rawValue,
                bitrate: AgoraVideoBitrateStandard,
                orientationMode: .fixedPortrait,
                mirrorMode: .disabled
            )
        )
        let option = AgoraRtcChannelMediaOptions()
        option.publishCustomVideoTrack = true
        engine.updateChannel(with: option)
        videoSeatActive = true
        AppLogger.party.info("[PartyRTC] enableVideoSeat 360x640@15fps")
    }

    /// 关闭视频位推帧。
    @MainActor
    func disableVideoSeat() {
        guard videoSeatActive else { return }
        disableVideoSeatInternal()
    }

    private func disableVideoSeatInternal() {
        guard let engine else { return }
        let option = AgoraRtcChannelMediaOptions()
        option.publishCustomVideoTrack = false
        engine.updateChannel(with: option)
        engine.enableLocalVideo(false)
        engine.disableVideo()
        videoSeatActive = false
        AppLogger.party.info("[PartyRTC] disableVideoSeat")
    }

    /// 视频位本端推帧入口。PartyStore 在 CameraManager 订阅字典 sink 内调用。
    func pushFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let engine, state == .joined, videoSeatActive else { return }
        let frame = AgoraVideoFrame()
        frame.format = AgoraVideoFormat.cvPixelBGRA.rawValue
        frame.textureBuf = pixelBuffer
        frame.rotation = 0
        engine.pushExternalVideoFrame(frame, videoTrackId: 0)
    }

    // MARK: - leave

    /// 离开频道（async + CheckedContinuation 等 didLeaveChannel 回调；500ms 兜底防 SDK 漏调）。
    /// **不调 `destroy()`**——保留 sharedEngine 单例供后续直播/通话/再进派对房复用（D v5.4 已踩坑）。
    @MainActor
    func leave() async {
        guard let engine else { return }

        // 先关推流（让远端尽快感知离开）
        let option = AgoraRtcChannelMediaOptions()
        option.publishMicrophoneTrack = false
        option.publishCustomVideoTrack = false
        engine.updateChannel(with: option)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if leaveContinuation != nil {
                // 已有 leave 在等 → 直接 resume 当前 cont，避免 leaveChannel 重复调用
                cont.resume()
                return
            }
            leaveContinuation = cont
            engine.leaveChannel(nil)
            // 500ms 兜底：极小概率 SDK 漏调 didLeaveChannelWith
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                if let c = self.leaveContinuation {
                    self.leaveContinuation = nil
                    c.resume()
                    AppLogger.party.notice("[PartyRTC] leave 500ms timeout, fallback resume")
                }
            }
        }

        engine.disableAudio()
        if videoSeatActive { engine.disableVideo() }
        // 解绑 delegate 防后续直播侧收到派对房残留回调
        engine.delegate = nil
        self.engine = nil
        state = .idle
        remoteUids = []
        remoteVolumes = [:]
        videoSeatActive = false
        AppLogger.party.info("[PartyRTC] leave done")
    }
}

// MARK: - AgoraRtcEngineDelegate

extension PartyRTCEngine: AgoraRtcEngineDelegate {

    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinChannel channel: String, withUid uid: UInt, elapsed: Int) {
        AppLogger.party.info("[PartyRTC] didJoin ch=\(channel, privacy: .public) uid=\(uid, privacy: .public) elapsed=\(elapsed, privacy: .public)ms")
        Task { @MainActor in
            self.state = .joined
            self.delegate?.partyRTCEngineDidJoin(self)
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinedOfUid uid: UInt, elapsed: Int) {
        Task { @MainActor in
            self.remoteUids.insert(uid)
            self.delegate?.partyRTCEngine(self, didJoinedRemoteUid: uid)
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOfflineOfUid uid: UInt, reason: AgoraUserOfflineReason) {
        Task { @MainActor in
            self.remoteUids.remove(uid)
            self.remoteVolumes.removeValue(forKey: uid)
            self.delegate?.partyRTCEngine(self, didOfflineRemoteUid: uid)
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didLeaveChannelWith stats: AgoraChannelStats) {
        AppLogger.party.info("[PartyRTC] didLeave duration=\(stats.duration, privacy: .public)s")
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let c = self.leaveContinuation {
                self.leaveContinuation = nil
                c.resume()
            }
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) {
        AppLogger.party.error("[PartyRTC] error code=\(errorCode.rawValue, privacy: .public)")
        Task { @MainActor in
            if self.state == .joining {
                self.state = .failed("rtc_\(errorCode.rawValue)")
            }
            self.delegate?.partyRTCEngine(self, didFailWithReason: "rtc_\(errorCode.rawValue)")
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, connectionChangedTo state: AgoraConnectionState, reason: AgoraConnectionChangedReason) {
        AppLogger.party.notice("[PartyRTC] connection state=\(state.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        // 被踢 / 永久断开：通知 PartyStore（M4 内对接 forceLeaveRoom）
        if reason == .reasonBannedByServer {
            Task { @MainActor in self.delegate?.partyRTCEngine(self, didFailWithReason: "banned_by_server") }
        } else if reason == .reasonJoinFailed {
            Task { @MainActor in self.delegate?.partyRTCEngine(self, didFailWithReason: "join_failed") }
        }
    }

    /// 声波回调（02-04 §3.2 麦位高亮信号源）。MVP 仅打日志 + 写 remoteVolumes；F 期消费。
    func rtcEngine(_ engine: AgoraRtcEngineKit, reportAudioVolumeIndicationOfSpeakers speakers: [AgoraRtcAudioVolumeInfo], totalVolume: Int) {
        // 仅 debug 级日志，避免 500ms 一次轰炸 info
        AppLogger.party.debug("[PartyRTC] volume total=\(totalVolume, privacy: .public) speakers=\(speakers.count, privacy: .public)")
    }
}

// MARK: - delegate 协议（PartyStore 实现）

@MainActor
protocol PartyRTCEngineDelegate: AnyObject {
    func partyRTCEngineDidJoin(_ engine: PartyRTCEngine)
    func partyRTCEngine(_ engine: PartyRTCEngine, didJoinedRemoteUid uid: UInt)
    func partyRTCEngine(_ engine: PartyRTCEngine, didOfflineRemoteUid uid: UInt)
    func partyRTCEngine(_ engine: PartyRTCEngine, didFailWithReason reason: String)
}
