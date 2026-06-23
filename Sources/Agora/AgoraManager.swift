import AgoraRtcKit
import CoreVideo
import UIKit
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "Agora")

/// 声网 RTC 管理（B 里程碑 spec §7）：引擎初始化 / 加入/离开频道 / 外部视频帧推送 / 远端渲染。
///
/// M2 接入项：
/// - `networkQuality` 回调转发 NetworkQualityMonitor.report
/// - `tokenPrivilegeWillExpire` 真正续期（拉新 token → renewToken）
/// - 109/110 error code 同链路；续期失败 → store.forceEnd(.disconnected)
final class AgoraManager: NSObject, ObservableObject {
    enum State: String {
        case idle = "未加入"
        case joining = "加入中…"
        case joined = "已加入频道"
        case failed = "加入失败"
    }

    /// 视频编码档位（B 里程碑 spec §4 v5 弱网降级用）。
    /// `normal` = 720×1280 / 30fps；`low` = 720×1280 / 15fps（仅降帧率，保留分辨率避免 reset 抖动）
    enum EncoderQuality {
        case normal
        case low
    }

    @Published var state: State = .idle
    @Published var remoteUid: UInt = 0
    @Published var message: String = ""

    /// 远端画面渲染目标（交给声网 setupRemoteVideo）
    let remoteView = UIView()

    /// LiveStore 引用（M2 注入；token 续期失败时触发 forceEnd）
    weak var liveStore: LiveStore?
    /// 网络监控（M2 注入；networkQuality 回调转发）
    weak var networkMonitor: NetworkQualityMonitor?

    private var engine: AgoraRtcEngineKit?
    private let externalTrackId: UInt = 0

    /// token 续期失败次数（spec §7.2：两次失败 → forceEnd）
    private var renewFailureCount = 0
    /// 续期进行中标志（v5 review 阻塞 #2：防止 109/110 短时间多次回调并发续期）
    private var isRenewing = false

    /// D 里程碑修复（v5.4 直播私 call 卡死根因）：
    /// `leave()` 用 CheckedContinuation 桥接 `engine.leaveChannel` 异步回调，
    /// 等 SDK 真正 `didLeaveChannelWith` 后再返回，避免后续 `sharedEngine(with:)` 拿到
    /// 半离开/正在销毁的 singleton（导致主播 join 通话 channel 实际未生效）。
    /// 500ms 兜底防 SDK 漏调；所有读写均在 MainActor 上串行，无竞态。
    private var leaveContinuation: CheckedContinuation<Void, Never>?

    /// 当前视频编码档位（弱网降级 / 恢复时切换）
    private(set) var currentQuality: EncoderQuality = .normal

    var isActive: Bool { state == .joined || state == .joining }

    // MARK: - 加入

    func join(channelId: String,
              token: String,
              uid: UInt,
              profile: AgoraChannelProfile = .liveBroadcasting) {
        guard engine == nil else { return }

        let config = AgoraRtcEngineConfig()
        config.appId = AgoraConfig.appId
        config.channelProfile = profile
        let kit = AgoraRtcEngineKit.sharedEngine(with: config, delegate: self)
        // D 里程碑修复（v5.4）：sharedEngine 复用 singleton 时忽略新 config，
        // delegate / channelProfile 仍保留首次创建的值；直播 ↔ 通话 profile 切换必须显式重设。
        kit.delegate = self
        kit.setChannelProfile(profile)
        engine = kit

        kit.enableVideo()
        kit.enableAudio()

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
        option.publishCustomVideoTrack = true
        option.publishMicrophoneTrack = true
        option.autoSubscribeAudio = true
        option.autoSubscribeVideo = true

        state = .joining
        message = ""
        logger.info("joinChannel channel=\(channelId) uid=\(uid)")
        let ret = kit.joinChannel(byToken: token,
                                  channelId: channelId,
                                  uid: uid,
                                  mediaOptions: option)
        if ret != 0 {
            logger.error("joinChannel failed ret=\(ret)")
            state = .failed
            message = "joinChannel 调用失败: \(ret)"
        }
    }

    // MARK: - 推帧

    func pushFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let engine = engine, state == .joined else { return }
        let frame = AgoraVideoFrame()
        frame.format = AgoraVideoFormat.cvPixelBGRA.rawValue
        frame.textureBuf = pixelBuffer
        frame.rotation = 0
        engine.pushExternalVideoFrame(frame, videoTrackId: externalTrackId)
    }

    // MARK: - 离开

    /// D 里程碑修复（v5.4）：改 async，等 `didLeaveChannelWith` 回调到达再返回。
    /// 不再调用 `AgoraRtcEngineKit.destroy()`（销毁全进程 SDK 单例会导致紧接的 join 拿到半销毁实例
    /// → 主播未真正加入通话 channel → 用户端 didJoinedOfUid 永不触发）。
    /// 对齐 H5 `callApi.destory(false)` 仅 leave channel、不销毁 rtcClient。
    /// 500ms 兜底防 SDK 漏调回调。
    @MainActor
    func leave() async {
        guard let engine = engine else { return }
        let option = AgoraRtcChannelMediaOptions()
        option.publishCustomVideoTrack = false
        option.publishMicrophoneTrack = false
        engine.updateChannel(with: option)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // 已有 leave 在等待 → 直接 resume，避免重复 leaveChannel 调用
            if leaveContinuation != nil {
                cont.resume()
                return
            }
            leaveContinuation = cont
            engine.leaveChannel(nil)
            // 500ms 兜底：SDK 极小概率漏调 didLeaveChannelWith，避免永久挂起
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                if let c = self.leaveContinuation {
                    self.leaveContinuation = nil
                    c.resume()
                    logger.warning("leaveChannel didLeaveChannel 回调 500ms 超时，由兜底 resume")
                }
            }
        }

        engine.disableVideo()
        engine.disableAudio()
        // 不再调用 AgoraRtcEngineKit.destroy()——保留 SDK 单例供后续 join 复用
        self.engine = nil
        state = .idle
        remoteUid = 0
        message = ""
        renewFailureCount = 0
        currentQuality = .normal
    }

    /// 真正退出 App / 登出时再彻底销毁 SDK 单例。本次修复不强求调用方，列为后续 backlog（SessionStore.logout）。
    static func destroyEngine() {
        AgoraRtcEngineKit.destroy()
        logger.info("AgoraRtcEngineKit.destroy() invoked")
    }

    // MARK: - 编码档位切换（B 里程碑 spec §4 v5 弱网降级）

    /// 由 NetworkQualityMonitor 调用：弱网累计 ≥10 次 → .low；恢复 ≥5 次 → .normal。
    /// 已是目标档位时跳过；engine 未 join 时跳过。
    func applyEncoderQuality(_ q: EncoderQuality) {
        guard let engine, currentQuality != q else { return }
        let fps = (q == .normal) ? AgoraVideoFrameRate.fps30.rawValue : AgoraVideoFrameRate.fps15.rawValue
        // v5.1：low 模式同时降码率到 600kbps（弱网下 Standard 自适应不够激进，画面会卡）
        let bitrate = (q == .normal) ? AgoraVideoBitrateStandard : 600
        let config = AgoraVideoEncoderConfiguration(
            size: CGSize(width: 720, height: 1280),
            frameRate: fps,
            bitrate: bitrate,
            orientationMode: .fixedPortrait,
            mirrorMode: .disabled
        )
        engine.setVideoEncoderConfiguration(config)
        currentQuality = q
        logger.info("encoder quality → \(q == .normal ? "normal/30fps/auto" : "low/15fps/600kbps")")
    }

    // MARK: - token 续期（spec §7）

    /// 拉新 rtcToken → engine.renewToken；失败 ≥2 次触发 forceEnd(.disconnected)
    /// v5 review 修复：
    /// - 阻塞 #2：isRenewing 守卫防 109/110 短时间多次回调并发续期（后到达的成功会覆盖新 token）
    /// - 阻塞 #3：成功后清 message + 把 .failed 态扳回 .joined
    /// **v5.3.3 修复**：后台时不续期，避免后台 109/110 backlog + URLSession 后台 timeout 累计 renewFailureCount→forceEnd
    /// `willEnterForeground` 时 SDK 通常会重新发 tokenPrivilegeWillExpire 或 109，自然触发续期
    private func renewToken() {
        guard UIApplication.shared.applicationState != .background else {
            logger.info("skip token renew in background")
            return
        }
        guard !isRenewing else {
            logger.info("renewToken already in flight, skip")
            return
        }
        isRenewing = true
        Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.isRenewing = false } }
            do {
                let res = try await LiveService.getAgoraRtmToken()
                guard let newToken = res.rtcToken, !newToken.isEmpty else {
                    throw NSError(domain: "Agora", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "rtcToken empty"])
                }
                self.engine?.renewToken(newToken)
                await MainActor.run {
                    self.renewFailureCount = 0
                    self.message = ""
                    if self.state == .failed { self.state = .joined }
                    logger.info("Agora token renewed")
                }
            } catch {
                await MainActor.run {
                    self.renewFailureCount += 1
                    let count = self.renewFailureCount
                    logger.error("Agora token renew failed (\(count)/2): \(String(describing: error))")
                    if count >= 2 {
                        Task { [weak self] in
                            await self?.liveStore?.forceEnd(reason: .disconnected,
                                                            subSource: "agora_token_renew_failed")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 声网回调

extension AgoraManager: AgoraRtcEngineDelegate {
    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinChannel channel: String, withUid uid: UInt, elapsed: Int) {
        logger.info("local joined channel=\(channel) uid=\(uid) elapsed=\(elapsed)ms")
        DispatchQueue.main.async {
            self.state = .joined
            self.message = "本地已加入 uid=\(uid)"
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinedOfUid uid: UInt, elapsed: Int) {
        logger.info("remote joined uid=\(uid)")
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
        logger.error("RTC error code \(errorCode.rawValue)")
        DispatchQueue.main.async {
            self.message = "RTC 错误码: \(errorCode.rawValue)"
            if self.state == .joining { self.state = .failed }
            // 109/110 走续期链路（spec §7.2）
            if errorCode.rawValue == 109 || errorCode.rawValue == 110 {
                self.renewToken()
            }
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, tokenPrivilegeWillExpire token: String) {
        logger.info("tokenPrivilegeWillExpire → renew")
        DispatchQueue.main.async {
            self.renewToken()
        }
    }

    /// 网络质量回调转发到 NetworkQualityMonitor（spec §4.1）
    func rtcEngine(_ engine: AgoraRtcEngineKit,
                   networkQuality uid: UInt,
                   txQuality: AgoraNetworkQuality,
                   rxQuality: AgoraNetworkQuality) {
        guard uid == 0 else { return }  // 0 表示本地
        Task { @MainActor [weak self] in
            self?.networkMonitor?.report(tx: txQuality, rx: rxQuality)
        }
    }

    /// D 里程碑修复（v5.4）：本地 leave channel 完成回调 → resume leave() 内的 continuation
    func rtcEngine(_ engine: AgoraRtcEngineKit, didLeaveChannelWith stats: AgoraChannelStats) {
        logger.info("local left channel duration=\(stats.duration)s")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let c = self.leaveContinuation {
                self.leaveContinuation = nil
                c.resume()
            }
        }
    }
}
