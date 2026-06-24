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

    /// 视频编码档位（B 里程碑 spec §4 弱网降级 + G 里程碑 spec §3.5 PK 期降分辨率）。
    /// - `normal` 720×1280 / 30fps / Standard 自适应
    /// - `low` 720×1280 / 15fps / 600kbps（弱网降级）
    /// - `pkActive` 480×640 / 30fps / 500kbps（PK 期默认档位）
    /// - `pkLow` 480×640 / 15fps / 400kbps（PK 期 + 弱网叠加）
    /// 注意：setVideoEncoderConfiguration 是 engine 级别，会同时影响主频道观众端画质（R9）
    enum EncoderQuality {
        case normal
        case low
        case pkActive
        case pkLow
    }

    /// G 里程碑 M0 新增：多频道 join 失败错误类型。
    enum AgoraError: Error {
        case engineNotReady
        case joinExFailed(code: Int)
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

    // MARK: - G 里程碑 PK 多频道（spec §3）

    /// PK 对手画面渲染目标（M3 PKArenaView 接入；M0 阶段未挂 UI 也保留实例避免空判散落）
    let oppositeRemoteView = UIView()

    /// 多频道字典 + leave continuation 字典的串行锁。
    /// 读写来自两端：MainActor（joinPKOpposite/leavePKOpposite 调用方）+ SDK 回调子线程
    /// （PKChannelDelegate.didLeaveChannelExWith / pkConnection(forChannel:)）。
    /// 锁内仅做字典 get/set，锁外再执行 SDK 调用，避免长持锁阻塞 main queue。
    private let pkLock = NSLock()
    /// 已 join 的 PK 频道 connection 字典，key = channelId
    private var pkConnections: [String: AgoraRtcConnection] = [:]
    /// 每个 PK 频道对应的独立 delegate，强引用避免 SDK 持有 weak 后被释放
    private var pkDelegates: [String: PKChannelDelegate] = [:]
    /// leavePKOpposite 的 CheckedContinuation 字典，key = channelId；500ms 兜底 + 实际回调任一先到 resume 一次
    private var leavePKContinuations: [String: CheckedContinuation<Void, Never>] = [:]

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

    // MARK: - PK 多频道 join / leave（G 里程碑 spec §3）

    /// 加入对手 PK 频道（作为 audience 仅订阅、不推流），用 joinChannelEx + AgoraRtcConnection。
    /// - 幂等：同 channel 重复调用直接 return
    /// - join 成功后立刻把编码档位切到 `.pkActive`（PK 期默认）
    /// - join 失败抛 `AgoraError.joinExFailed(code:)`，字典回滚
    /// - 长跑验证（M0-3）：renewToken 是否自动覆盖 PK connection；失败则改逐 connection renewTokenEx（R10）
    @MainActor
    func joinPKOpposite(channel: String, oppositeUid: UInt, token: String, ownUid: UInt) async throws {
        guard let engine else { throw AgoraError.engineNotReady }

        // 幂等：channel 已在 pkConnections 直接返回
        pkLock.lock()
        let exists = pkConnections[channel] != nil
        pkLock.unlock()
        if exists {
            logger.info("joinPKOpposite skipped: channel \(channel) already joined")
            return
        }

        let conn = AgoraRtcConnection()
        conn.channelId = channel
        conn.localUid = ownUid

        let delegate = PKChannelDelegate(owner: self, channel: channel, oppositeUid: oppositeUid)

        let option = AgoraRtcChannelMediaOptions()
        option.clientRoleType = .audience          // PK 对手频道我们仅观看
        option.publishCustomVideoTrack = false
        option.publishMicrophoneTrack = false
        option.autoSubscribeAudio = true
        option.autoSubscribeVideo = true

        // 先写入字典：保证后续 SDK 回调 lookup 时引用已就位
        pkLock.lock()
        pkConnections[channel] = conn
        pkDelegates[channel] = delegate
        pkLock.unlock()

        logger.info("joinChannelEx PK channel=\(channel) oppositeUid=\(oppositeUid) ownUid=\(ownUid)")
        let ret = engine.joinChannelEx(byToken: token,
                                       connection: conn,
                                       delegate: delegate,
                                       mediaOptions: option,
                                       joinSuccess: nil)
        if ret != 0 {
            logger.error("joinChannelEx PK failed channel=\(channel) ret=\(ret)")
            pkLock.lock()
            pkConnections.removeValue(forKey: channel)
            pkDelegates.removeValue(forKey: channel)
            pkLock.unlock()
            throw AgoraError.joinExFailed(code: Int(ret))
        }

        // 首次 PK 频道 join 成功 → 切 .pkActive；幂等 applyEncoderQuality 内已守 currentQuality 相等
        applyEncoderQuality(.pkActive)
    }

    /// 离开对手 PK 频道（continuation 桥接 + 500ms 兜底）。
    /// - 字典清理在 await 之后；全部 PK 频道清空时回切 `.normal` 档位
    /// - 兜底与回调任一先到都安全：resumeLeavePKContinuation 在锁内 removeValue 拿 cont 才 resume
    @MainActor
    func leavePKOpposite(channel: String) async {
        guard let engine else { return }

        pkLock.lock()
        let conn = pkConnections[channel]
        pkLock.unlock()
        guard let connection = conn else { return }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pkLock.lock()
            if leavePKContinuations[channel] != nil {
                // 已有 leave 在等待，直接 resume 避免重复 leaveChannelEx
                pkLock.unlock()
                cont.resume()
                return
            }
            leavePKContinuations[channel] = cont
            pkLock.unlock()

            _ = engine.leaveChannelEx(connection, leaveChannelBlock: nil)

            // 500ms 兜底：若 didLeaveChannelExWith 漏调，由本兜底 resume 同 channel 的 continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.resumeLeavePKContinuation(channel: channel)
            }
        }

        pkLock.lock()
        pkConnections.removeValue(forKey: channel)
        pkDelegates.removeValue(forKey: channel)
        let empty = pkConnections.isEmpty
        pkLock.unlock()

        if empty {
            applyEncoderQuality(.normal)
        }
    }

    /// PKChannelDelegate 在 SDK 子线程读字典；锁内拷贝引用 + 锁外返回，避免长持锁。
    nonisolated func pkConnection(forChannel channel: String) -> AgoraRtcConnection? {
        pkLock.lock()
        let conn = pkConnections[channel]
        pkLock.unlock()
        return conn
    }

    /// PKChannelDelegate 在收到 didLeaveChannelExWith / 兜底 Task 在收到 500ms 超时时调用。
    /// CheckedContinuation.resume 线程安全，调度无 main actor 依赖。
    nonisolated func resumeLeavePKContinuation(channel: String) {
        pkLock.lock()
        let cont = leavePKContinuations.removeValue(forKey: channel)
        pkLock.unlock()
        cont?.resume()
    }

    // MARK: - 编码档位切换（B 里程碑 spec §4 v5 弱网降级）

    /// 由 NetworkQualityMonitor / PKStore 调用切档位。已是目标档位时跳过；engine 未 join 时跳过。
    /// - `.normal` 720×1280/30fps/Standard 自适应
    /// - `.low` 720×1280/15fps/600kbps（弱网降级）
    /// - `.pkActive` 480×640/30fps/500kbps（PK 期默认）
    /// - `.pkLow` 480×640/15fps/400kbps（PK 期 + 弱网叠加，由 PKStore 监听 NQM weakSevere 触发）
    func applyEncoderQuality(_ q: EncoderQuality) {
        guard let engine, currentQuality != q else { return }
        let size: CGSize
        let fps: Int
        let bitrate: Int
        let label: String
        switch q {
        case .normal:
            size = CGSize(width: 720, height: 1280)
            fps = AgoraVideoFrameRate.fps30.rawValue
            bitrate = AgoraVideoBitrateStandard
            label = "normal/720x1280/30fps/auto"
        case .low:
            size = CGSize(width: 720, height: 1280)
            fps = AgoraVideoFrameRate.fps15.rawValue
            bitrate = 600
            label = "low/720x1280/15fps/600kbps"
        case .pkActive:
            size = CGSize(width: 480, height: 640)
            fps = AgoraVideoFrameRate.fps30.rawValue
            bitrate = 500
            label = "pkActive/480x640/30fps/500kbps"
        case .pkLow:
            size = CGSize(width: 480, height: 640)
            fps = AgoraVideoFrameRate.fps15.rawValue
            bitrate = 400
            label = "pkLow/480x640/15fps/400kbps"
        }
        let config = AgoraVideoEncoderConfiguration(
            size: size,
            frameRate: fps,
            bitrate: bitrate,
            orientationMode: .fixedPortrait,
            mirrorMode: .disabled
        )
        engine.setVideoEncoderConfiguration(config)
        currentQuality = q
        logger.info("encoder quality → \(label)")
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
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state = .joined
            self.message = "本地已加入 uid=\(uid)"
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinedOfUid uid: UInt, elapsed: Int) {
        logger.info("remote joined uid=\(uid)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.remoteUid = uid
            let canvas = AgoraRtcVideoCanvas()
            canvas.uid = uid
            canvas.view = self.remoteView
            canvas.renderMode = .hidden
            engine.setupRemoteVideo(canvas)
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOfflineOfUid uid: UInt, reason: AgoraUserOfflineReason) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.remoteUid == uid else { return }
            self.remoteUid = 0
            let canvas = AgoraRtcVideoCanvas()
            canvas.uid = uid
            canvas.view = nil
            engine.setupRemoteVideo(canvas)
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) {
        logger.error("RTC error code \(errorCode.rawValue)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
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
        DispatchQueue.main.async { [weak self] in
            self?.renewToken()
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
