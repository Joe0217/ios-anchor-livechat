import AgoraRtcKit
import CoreVideo
import UIKit

/// 声网 RTC 管理：引擎初始化、加入/离开频道、推送外部视频帧（相机/美颜后的画面）、远端渲染。
///
/// 视频走"自定义视频源"：本地相机帧经美颜后通过 pushExternalVideoFrame 推给声网编码，
/// 本地预览仍用我们自己的 Metal 视图（声网官方说明：推外部帧时 setupLocalVideo 不生效）。
/// 音频用声网自采集麦克风。
final class AgoraManager: NSObject, ObservableObject {
    enum State: String {
        case idle = "未加入"
        case joining = "加入中…"
        case joined = "已加入频道"
        case failed = "加入失败"
    }

    @Published var state: State = .idle
    @Published var remoteUid: UInt = 0
    @Published var message: String = ""

    /// 远端画面渲染目标（交给声网 setupRemoteVideo）
    let remoteView = UIView()

    private var engine: AgoraRtcEngineKit?
    /// setExternalVideoSource 对应的默认外部视频轨 id
    private let externalTrackId: UInt = 0

    var isActive: Bool { state == .joined || state == .joining }

    // MARK: - 加入

    /// 直播传 .liveBroadcasting（主播推流）；1v1 通话传 .communication（双方平等）。
    func join(channelId: String,
              token: String,
              uid: UInt,
              profile: AgoraChannelProfile = .liveBroadcasting) {
        guard engine == nil else { return }

        let config = AgoraRtcEngineConfig()
        config.appId = AgoraConfig.appId
        config.channelProfile = profile
        let kit = AgoraRtcEngineKit.sharedEngine(with: config, delegate: self)
        engine = kit

        kit.enableVideo()
        kit.enableAudio()

        // 启用外部视频源（我们推相机/美颜帧）
        kit.setExternalVideoSource(true, useTexture: true, sourceType: .videoFrame)
        kit.setVideoEncoderConfiguration(
            AgoraVideoEncoderConfiguration(
                size: CGSize(width: 720, height: 1280),
                frameRate: AgoraVideoFrameRate.fps30.rawValue,
                bitrate: AgoraVideoBitrateStandard,
                orientationMode: .fixedPortrait,
                mirrorMode: .disabled
            )
        )
        kit.setDefaultAudioRouteToSpeakerphone(true)

        let option = AgoraRtcChannelMediaOptions()
        option.clientRoleType = .broadcaster
        option.publishCustomVideoTrack = true   // 推外部视频帧
        option.publishMicrophoneTrack = true    // 麦克风（声网自采集）
        option.autoSubscribeAudio = true
        option.autoSubscribeVideo = true

        state = .joining
        message = ""
        print("🟡 [Agora] joinChannel channel=\(channelId) uid=\(uid)")
        let ret = kit.joinChannel(byToken: token,
                                  channelId: channelId,
                                  uid: uid,
                                  mediaOptions: option)
        print("🟡 [Agora] joinChannel 返回 ret=\(ret)")
        if ret != 0 {
            state = .failed
            message = "joinChannel 调用失败: \(ret)"
        }
    }

    // MARK: - 推帧

    /// 由相机帧回调调用（已经过美颜处理）。注意：当前帧为前置镜像，远端看到的是镜像画面（POC 暂不处理）。
    func pushFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let engine = engine, state == .joined else { return }
        let frame = AgoraVideoFrame()
        frame.format = AgoraVideoFormat.cvPixelBGRA.rawValue  // 相机输出 BGRA
        frame.textureBuf = pixelBuffer
        frame.rotation = 0  // 相机已设为竖屏
        engine.pushExternalVideoFrame(frame, videoTrackId: externalTrackId)
    }

    // MARK: - 离开

    func leave() {
        guard let engine = engine else { return }
        let option = AgoraRtcChannelMediaOptions()
        option.publishCustomVideoTrack = false
        option.publishMicrophoneTrack = false
        engine.updateChannel(with: option)
        engine.leaveChannel(nil)
        engine.disableVideo()
        engine.disableAudio()
        AgoraRtcEngineKit.destroy()
        self.engine = nil
        state = .idle
        remoteUid = 0
        message = ""
    }
}

// MARK: - 声网回调

extension AgoraManager: AgoraRtcEngineDelegate {
    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinChannel channel: String, withUid uid: UInt, elapsed: Int) {
        print("🟢 [Agora] 本地加入成功 channel=\(channel) uid=\(uid) elapsed=\(elapsed)ms")
        DispatchQueue.main.async {
            self.state = .joined
            self.message = "本地已加入 uid=\(uid)"
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinedOfUid uid: UInt, elapsed: Int) {
        print("🟢 [Agora] 远端用户加入 uid=\(uid)")
        DispatchQueue.main.async {
            self.remoteUid = uid
            let canvas = AgoraRtcVideoCanvas()
            canvas.uid = uid
            canvas.view = self.remoteView
            canvas.renderMode = .hidden
            engine.setupRemoteVideo(canvas)
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOfflineOfUid uid: UInt, reason: AgoraUserOfflineReason) {
        DispatchQueue.main.async {
            guard self.remoteUid == uid else { return }
            self.remoteUid = 0
            let canvas = AgoraRtcVideoCanvas()
            canvas.uid = uid
            canvas.view = nil
            engine.setupRemoteVideo(canvas)
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) {
        // 110 = token 无效；109 = token 过期
        print("🔴 [Agora] 错误码 \(errorCode.rawValue)（110=token无效, 109=token过期）")
        DispatchQueue.main.async {
            self.message = "RTC 错误码: \(errorCode.rawValue)"
            if self.state == .joining { self.state = .failed }
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, tokenPrivilegeWillExpire token: String) {
        DispatchQueue.main.async {
            self.message = "token 即将过期，请更新 AgoraConfig.token"
        }
    }
}
