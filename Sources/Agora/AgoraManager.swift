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
    /// 主播推流与客态观看使用同一 RTC 引擎，但 channel media options 完全不同。
    /// 把角色显式收在这里，避免客态误发布本地音视频或初始化外部视频帧来源。
    enum JoinRole: Equatable {
        case broadcaster
        case audience
    }
    /// rawValue 走英文 internal code（用于 logger / 调试日志，绝不直接显示到 UI）；
    /// 用户可见的 status 文案统一走 `var label: String` 经 L10n。
    enum State: String {
        case idle
        case joining
        case joined
        case failed

        /// 用户可见的本地化文案；直播和通话页面显示用本字段。
        var label: String {
            switch self {
            case .idle:    return L10n.liveRoomStatusIdle
            case .joining: return L10n.liveRoomStatusConnecting
            case .joined:  return L10n.liveRoomStatusJoined
            case .failed:  return L10n.liveRoomStatusFailed
            }
        }
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
    /// C-4 Wave4 C 组 gap-010：远端主动关摄像头（.remoteMuted）时 true → CallView 叠占位（对方头像 + "Camera off"）。
    /// 远端离开（didOfflineOfUid）/ leave() 时 reset false（不是关摄语义）。
    @Published var isRemoteVideoOff: Bool = false

    /// 本地/远端网络质量（AgoraNetworkQuality raw：0 unknown / 1 excellent / 2 good / 3 poor / 4 bad / 5 vBad / 6 down）
    /// 由 `rtcEngine.networkQuality` delegate 每 ~2s 上报。UI 层（CallFaceTimeView.signalColumn）消费展示 You/User 双向条形。
    /// 弱网降级链路（NetworkQualityMonitor + callNetworkQualityHandler）**仅**消费 localSignalLevel 派生的 worst=max(tx,rx)，
    /// 与 UI 展示的原始 tx/rx 语义分离。
    @Published var localSignalLevel: Int = 0
    @Published var remoteSignalLevel: Int = 0

    /// 远端画面渲染目标（交给声网 setupRemoteVideo）
    let remoteView = UIView()

    /// LiveStore 引用（M2 注入；token 续期失败时触发 forceEnd）
    weak var liveStore: LiveStore?
    /// 网络监控（M2 注入；networkQuality 回调转发）
    weak var networkMonitor: NetworkQualityMonitor?

    /// C 里程碑：通话侧独立弱网观察 closure。CallStore.init 挂 / stop 清；参数 = max(tx.rawValue, rx.rawValue) 0-6。
    /// 与直播侧 `networkMonitor` 独立计数不干扰：LiveStore .living 时两者同时累计各自计数是合理的
    /// （通话中若 LiveStore=.living 则是直播私 call 场景，两侧观察的是同一 RTC 通道质量）。
    @MainActor var callNetworkQualityHandler: ((Int) -> Void)?

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
              profile: AgoraChannelProfile = .liveBroadcasting,
              role: JoinRole = .broadcaster) {
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

        if role == .broadcaster {
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
        } else {
            // sharedEngine 可能来自上一场主播直播；客态必须主动关闭外部帧源，
            // 否则退出主播房后立刻进他人直播间仍可能错误保留 publish track。
            kit.setExternalVideoSource(false, useTexture: true, sourceType: .videoFrame)
        }
        kit.setDefaultAudioRouteToSpeakerphone(true)

        let option = AgoraRtcChannelMediaOptions()
        option.clientRoleType = role == .broadcaster ? .broadcaster : .audience
        option.publishCustomVideoTrack = role == .broadcaster
        option.publishMicrophoneTrack = role == .broadcaster
        option.autoSubscribeAudio = true
        option.autoSubscribeVideo = true

        state = .joining
        message = ""
        logger.info("joinChannel channel=\(channelId) uid=\(uid) role=\(role == .broadcaster ? "broadcaster" : "audience")")
        let ret = kit.joinChannel(byToken: token,
                                  channelId: channelId,
                                  uid: uid,
                                  mediaOptions: option)
        if ret != 0 {
            logger.error("joinChannel failed ret=\(ret)")
            state = .failed
            message = String(format: L10n.liveRoomStatusJoinChannelFailedFormat, ret)
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

    // MARK: - C 里程碑通话中控制

    /// 静音/取消静音本端麦克风（对应 H5 `toggleAudioMute`）。
    /// - 幂等：engine 未 join 时 no-op；重复相同 mute 值 no-op（SDK 内部也幂等，此处仅日志抑制）。
    /// - 不同于 `updateChannel(publishMicrophoneTrack:)`：muteLocalAudioStream 保持 track publish 但停发音频帧，
    ///   对端仍认为通话在线（不会误判掉线），仅"听不到声音"。切回 unmute 无需 restart channel。
    func muteLocalAudio(_ mute: Bool) {
        guard let engine else { return }
        engine.muteLocalAudioStream(mute)
        logger.info("muteLocalAudio: \(mute)")
    }

    /// C-4 Wave2 gap-critic-005：切后台/前台时暂停/恢复视频推流，音频始终保留。
    /// - iOS 限制 app 后台无法访问相机 → 主动 publishCustomVideoTrack=false 避免推黑帧
    /// - 音频 track 保持 publish=true（配合 Info.plist UIBackgroundModes=audio 与 AVAudioSession），
    ///   保证切后台通话不断音
    /// - engine 未 join 时 no-op；publishMicrophoneTrack 恒 true 不动
    func updateChannelPublishVideo(_ publish: Bool) {
        guard let engine else { return }
        let option = AgoraRtcChannelMediaOptions()
        option.publishCustomVideoTrack = publish
        option.publishMicrophoneTrack = true
        engine.updateChannel(with: option)
        logger.info("updateChannelPublishVideo: \(publish)")
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
        // 先关闭硬件采集，再等 leaveChannel 回调。SDK 回调漏发或网络异常时也不能继续占用麦克风/摄像头。
        engine.disableVideo()
        engine.disableAudio()

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

        // 不再调用 AgoraRtcEngineKit.destroy()——保留 SDK 单例供后续 join 复用
        self.engine = nil
        state = .idle
        remoteUid = 0
        isRemoteVideoOff = false  // C-4 Wave4 C 组 gap-010：leave 时 reset
        message = ""
        renewFailureCount = 0
        currentQuality = .normal

        // 清理残留的 PK 多频道字典：异常路径（forceEnd / 用户主动下播未先 leavePKOpposite）会跳过
        // 各 channel 的 leavePKOpposite 清理逻辑，字典残留会导致下次 join 幽灵 continuation 永挂。
        // 锁内快照 continuations 后清空，锁外 resume 避免持锁调外部代码。
        pkLock.lock()
        let pendingConts = leavePKContinuations
        leavePKContinuations.removeAll()
        pkConnections.removeAll()
        pkDelegates.removeAll()
        pkLock.unlock()
        pendingConts.values.forEach { $0.resume() }
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
        // M3 遗漏修复（2026-07-06 real-machine bug）：给 delegate 注入对手画面渲染 UIView。
        // PKChannelDelegate.didJoinedOfUid 内 `guard let view = self.oppositeView` 依赖此注入；
        // 之前从未赋值 → setupRemoteVideoEx 永不执行 → 对方视频黑屏（骨架 M0 注释「M3 接入」被遗漏至今）。
        // oppositeRemoteView 是 AgoraManager `let` 强持有的单例 UIView，weak reference 有效。
        delegate.oppositeView = self.oppositeRemoteView

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

    /// 客态 PK 收到主播的 `attachType=-8` 后，只静音对手扩展频道的音频；主直播频道音频保持不变。
    func mutePKOppositeAudio(channel: String, uid: UInt, muted: Bool) {
        guard let engine else { return }
        pkLock.lock()
        let connection = pkConnections[channel]
        pkLock.unlock()
        guard let connection else { return }
        engine.muteRemoteAudioStreamEx(uid, mute: muted, connection: connection)
        logger.info("PK opponent audio muted=\(muted) channel=\(channel, privacy: .public)")
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
            self.message = ""
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
        // 【归因日志】远端离开 RTC 频道：reason=0 (quit) / 1 (dropped) / 2 (becomeAudience)
        // 用户主动挂断 = 0；网络断连=1；1v1 场景不会出现 2
        logger.notice("🔴 [Agora] didOfflineOfUid uid=\(uid) reason=\(reason.rawValue) currentRemoteUid=\(self.remoteUid)")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.remoteUid == uid else { return }
            self.remoteUid = 0
            // C-4 Wave4 C 组 gap-010：远端离开 reset isRemoteVideoOff（离开是挂断链路，不是关摄）
            self.isRemoteVideoOff = false
            let canvas = AgoraRtcVideoCanvas()
            canvas.uid = uid
            canvas.view = nil
            engine.setupRemoteVideo(canvas)
        }
    }

    /// C-4 Wave4 C 组 gap-010 + gap-critic-003：远端视频状态变化（对方关/开摄像头）。
    /// - state == .stopped → 关摄像头 → CallView 叠占位（远端头像 + "Camera off"）
    /// - state 恢复非 stopped → 关摄状态解除
    /// - 只关心当前会话的远端 uid（PK 频道等其他 uid 走独立 delegate）
    ///
    /// **判据**：SDK state 4 值（stopped=0/starting=1/decoding=2/frozen=3/failed=4）；
    /// 保守取 .stopped 作为"关摄"判据（reason.remoteMuted 是理想信号但不同 SDK 版本触发条件有差异）。
    /// frozen 是弱网卡帧不是关摄，不算 off。
    func rtcEngine(_ engine: AgoraRtcEngineKit,
                   remoteVideoStateChangedOfUid uid: UInt,
                   state: AgoraVideoRemoteState,
                   reason: AgoraVideoRemoteReason,
                   elapsed: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.remoteUid == uid, uid > 0 else { return }
            let off = (state == .stopped)
            if self.isRemoteVideoOff != off {
                self.isRemoteVideoOff = off
                logger.info("remote video state=\(state.rawValue) reason=\(reason.rawValue) uid=\(uid, privacy: .private) → isRemoteVideoOff=\(off)")
            }
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) {
        logger.error("RTC error code \(errorCode.rawValue)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.message = String(format: L10n.liveRoomStatusRtcErrorFormat, errorCode.rawValue)
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

    /// 网络质量回调（spec §4.1 + C 里程碑通话 UI signalColumn）：
    /// - `uid == 0` = 本地：派 NetworkQualityMonitor.report（弱网降级）+ callNetworkQualityHandler（CallStore）+ 派 UI localSignalLevel
    /// - `uid != 0` = 远端：仅派 UI remoteSignalLevel（不参与弱网降级）
    /// 每 ~2s 触发一次；raw 值越大越差（0 unknown / 1 excellent / … / 6 down）
    func rtcEngine(_ engine: AgoraRtcEngineKit,
                   networkQuality uid: UInt,
                   txQuality: AgoraNetworkQuality,
                   rxQuality: AgoraNetworkQuality) {
        let worst = max(Int(txQuality.rawValue), Int(rxQuality.rawValue))
        Task { @MainActor [weak self] in
            guard let self else { return }
            if uid == 0 {
                let prev = self.localSignalLevel
                self.localSignalLevel = worst
                self.networkMonitor?.report(tx: txQuality, rx: rxQuality)
                self.callNetworkQualityHandler?(worst)
                if prev != worst {
                    logger.info("[networkQuality] local worst=\(worst) tx=\(txQuality.rawValue) rx=\(rxQuality.rawValue)")
                }
            } else {
                let prev = self.remoteSignalLevel
                self.remoteSignalLevel = worst
                // 只在 level 变化时 log（避免每 2s spam）。真机验收：查 Xcode Console filter subsystem=com.anchor.livechat category=Agora
                if prev != worst {
                    logger.info("[networkQuality] remote uid=\(uid) worst=\(worst) tx=\(txQuality.rawValue) rx=\(rxQuality.rawValue)")
                }
            }
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
