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

    /// v15：本地 Agora uid（join 时传入，用于 speakers.uid=0 → 真实 uid 映射；
    /// Agora `reportAudioVolumeIndicationOfSpeakers` 规定 uid=0 = 本地用户）
    private var localAgoraUid: UInt = 0

    weak var delegate: PartyRTCEngineDelegate?

    private var engine: AgoraRtcEngineKit?

    /// leave channel 异步等待句柄（D v5.4 模式）
    private var leaveContinuation: CheckedContinuation<Void, Never>?

    /// leave 500ms 兜底 Task 句柄（二轮复查 wfpw5v1us）：
    /// didLeaveChannelWith 正常 resume 时 cancel，避免 Task 泄漏 + 多余日志。
    private var leaveTimeoutTask: Task<Void, Never>?

    /// 视频位推帧是否已启用（默认 false，仅 `enableVideoSeat()` 后置 true）
    private(set) var videoSeatActive = false

    /// pushFrame 跨 actor 安全的状态快照（review 202606252033 P0-1）。
    /// pushFrame 是 nonisolated（CameraManager.videoQueue 调用），但 engine / state / videoSeatActive 在 @MainActor 写。
    /// 用 NSLock 守 frameSnapshot；任何 @MainActor 写完上述字段后调 `updateFrameSnapshot()` 刷新快照，
    /// pushFrame 锁内取快照 → 锁外推帧。`leave()` 置 nil 与 pushFrame 读字段的数据竞争由此消除（CLAUDE.md v5.3.1 同源）。
    private let frameLock = NSLock()
    private var frameSnapshot: (engine: AgoraRtcEngineKit?, active: Bool) = (nil, false)

    /// 远端视频位 UIView 池（spec v4 §4，按 seatIndex 缓存稳定实例 → SwiftUI redraw 不丢首帧）。
    /// 与 H5 `#partyMicDom-${seatIndex}` 对齐：池容量随麦位数懒增长，退房统一释放。
    /// rules `swiftui-camera-preview.md` §2：AgoraRtcVideoCanvas.view 反复 makeUIView 会丢首帧。
    private var seatIndexToView: [Int: UIView] = [:]

    /// 上次按 seatIndex 绑过的远端 uid（用于换人时拿旧 uid 清理 canvas）。
    /// key 缺失 = 该麦位从未绑过；value=0 = 已显式清理。
    private var seatIndexToBoundUid: [Int: UInt] = [:]

    /// 当前有效绑定的 seatIndex 集合（用于 PartyStore.postMikeList diff 对账，spec v4 §4）。
    /// 仅 @MainActor 调用 —— 字典写入路径（bindRemoteVideo / unbindRemoteVideo / releaseAllRemoteViews）均 @MainActor。
    @MainActor
    var boundRemoteSeatIndices: Set<Int> {
        Set(seatIndexToBoundUid.compactMap { $0.value > 0 ? $0.key : nil })
    }

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

        localAgoraUid = uid  // v15 声纹：speakers.uid=0 → localAgoraUid 映射用
        state = .joining
        AppLogger.party.info("[PartyRTC] joinChannel ch=\(channelId, privacy: .public) uid=\(uid, privacy: .public)")
        let ret = kit.joinChannel(byToken: token, channelId: channelId, uid: uid, mediaOptions: option)
        if ret != 0 {
            AppLogger.party.error("[PartyRTC] joinChannel failed ret=\(ret, privacy: .public)")
            state = .failed("joinChannel: \(ret)")
            delegate?.partyRTCEngine(self, didFailWithReason: "join_\(ret)")
        }
        updateFrameSnapshot()  // P0-1：写完 engine/state 必须刷新 pushFrame 快照
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
        updateFrameSnapshot()  // P0-1
    }

    /// 关闭视频位推帧。
    @MainActor
    func disableVideoSeat() {
        guard videoSeatActive else { return }
        disableVideoSeatInternal()
    }

    @MainActor
    private func disableVideoSeatInternal() {
        guard let engine else { return }
        let option = AgoraRtcChannelMediaOptions()
        option.publishCustomVideoTrack = false
        engine.updateChannel(with: option)
        engine.enableLocalVideo(false)
        engine.disableVideo()
        videoSeatActive = false
        AppLogger.party.info("[PartyRTC] disableVideoSeat")
        updateFrameSnapshot()  // P0-1
    }

    // MARK: - 远端视频流绑定（spec v4 §4 / H5 playVideoInDom 等价）

    /// 取按 seatIndex 缓存的远端渲染 UIView；不存在则懒创建后入池。
    /// **必须在 main thread** —— SwiftUI `UIViewRepresentable.makeUIView` 已是 main isolated。
    /// view 永远不复制不替换；后续 `setupRemoteVideo` 的 canvas.view 始终是池中实例（rules §2 关键）。
    @MainActor
    func acquireRemoteView(seatIndex: Int) -> UIView {
        if let existing = seatIndexToView[seatIndex] { return existing }
        let v = UIView()
        v.backgroundColor = .black
        v.isUserInteractionEnabled = false
        seatIndexToView[seatIndex] = v
        AppLogger.party.info("[PartyRTC] acquireRemoteView seatIndex=\(seatIndex, privacy: .public) created")
        return v
    }

    /// 绑定 seatIndex 对应的远端视频流到 (uid, view) canvas。
    /// 幂等：同 (seatIndex, uid) 重入 = no-op；不同 uid（换人）= 先清旧 uid 再绑新 uid。
    /// `autoSubscribeVideo` 已在 join 时置 true，无需 muteRemoteVideoStream(false)。
    @MainActor
    func bindRemoteVideo(seatIndex: Int, uid: UInt) {
        guard let engine, uid > 0 else { return }
        if let last = seatIndexToBoundUid[seatIndex], last == uid {
            return  // 幂等：无变化
        }
        // 换人：先清旧 uid 的 canvas（防 SDK 内部把新 view 错关联到旧 uid 流）
        if let last = seatIndexToBoundUid[seatIndex], last != 0, last != uid {
            let clear = AgoraRtcVideoCanvas()
            clear.uid = last
            clear.view = nil
            engine.setupRemoteVideo(clear)
            AppLogger.party.info("[PartyRTC] bindRemoteVideo replace seatIndex=\(seatIndex, privacy: .public) old=\(last, privacy: .public) new=\(uid, privacy: .public)")
        }
        let view = acquireRemoteView(seatIndex: seatIndex)
        let canvas = AgoraRtcVideoCanvas()
        canvas.uid = uid
        canvas.view = view
        canvas.renderMode = .hidden    // 等比裁剪铺满 56×56 圆形容器
        engine.setupRemoteVideo(canvas)
        seatIndexToBoundUid[seatIndex] = uid
        AppLogger.party.info("[PartyRTC] bindRemoteVideo seatIndex=\(seatIndex, privacy: .public) uid=\(uid, privacy: .public)")
    }

    /// 清理 seatIndex 对应远端 canvas（用上次绑过的 uid）。
    /// 不释放 view 池：进房期间 view 保留以便下个人上同位时复用。退房时统一 `releaseAllRemoteViews`。
    @MainActor
    func unbindRemoteVideo(seatIndex: Int) {
        guard let engine, let lastUid = seatIndexToBoundUid[seatIndex], lastUid != 0 else { return }
        let canvas = AgoraRtcVideoCanvas()
        canvas.uid = lastUid
        canvas.view = nil
        engine.setupRemoteVideo(canvas)
        seatIndexToBoundUid[seatIndex] = 0
        AppLogger.party.info("[PartyRTC] unbindRemoteVideo seatIndex=\(seatIndex, privacy: .public) uid=\(lastUid, privacy: .public)")
    }

    /// 释放整个远端 view 池（退房时调）。先逐个 unbind 让 SDK 解关联，再清字典。
    /// **P2-9**：keys 快照后迭代——unbindRemoteVideo 会写 seatIndexToBoundUid[seatIndex]=0，
    /// for-in 中 mutate 被迭代字典是 Swift 未定义行为，必须先快照。
    @MainActor
    func releaseAllRemoteViews() {
        for seatIndex in Array(seatIndexToBoundUid.keys) {
            unbindRemoteVideo(seatIndex: seatIndex)
        }
        seatIndexToBoundUid.removeAll()
        seatIndexToView.removeAll()
        AppLogger.party.info("[PartyRTC] releaseAllRemoteViews done")
    }

    /// 视频位本端推帧入口。PartyStore 在 CameraManager 订阅字典 sink 内调用（videoQueue 后台线程）。
    /// **跨 actor 安全**：锁内取 frameSnapshot 快照，锁外用快照推帧；与 @MainActor 写 engine/state/videoSeatActive 的链路通过锁完全隔离。
    func pushFrame(_ pixelBuffer: CVPixelBuffer) {
        frameLock.lock()
        let snap = frameSnapshot
        frameLock.unlock()
        guard let engine = snap.engine, snap.active else { return }
        let frame = AgoraVideoFrame()
        frame.format = AgoraVideoFormat.cvPixelBGRA.rawValue
        frame.textureBuf = pixelBuffer
        frame.rotation = 0
        engine.pushExternalVideoFrame(frame, videoTrackId: 0)
    }

    /// 刷新 pushFrame 用的状态快照（P0-1 修复配套）。
    /// 在 @MainActor 路径写完 engine / state / videoSeatActive 后必须调；
    /// 触发点：join 失败 / didJoinChannel / enableVideoSeat / disableVideoSeatInternal / leave。
    @MainActor
    private func updateFrameSnapshot() {
        let nextEngine = engine
        let nextActive = (state == .joined && videoSeatActive)
        frameLock.lock()
        frameSnapshot = (nextEngine, nextActive)
        frameLock.unlock()
    }

    // MARK: - leave

    /// 离开频道（async + CheckedContinuation 等 didLeaveChannel 回调；500ms 兜底防 SDK 漏调）。
    /// **不调 `destroy()`**——保留 sharedEngine 单例供后续直播/通话/再进派对房复用（D v5.4 已踩坑）。
    @MainActor
    func leave() async {
        guard let engine else { return }

        // 二轮复查 wfpw5v1us：本地快照 wasVideoActive
        // 必须在 videoSeatActive=false 之前取值，否则 line 358 永远走不到 disableVideo() 分支（死分支 / video source 不释放）
        let wasVideoActive = videoSeatActive

        // P0-1：进 leave 立即作废 pushFrame 快照，防止 didLeave 回调返回前 captureOutput 仍在推帧到正在销毁的 channel
        videoSeatActive = false
        updateFrameSnapshot()

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
            // 二轮复查 wfpw5v1us：保存 Task 句柄，didLeaveChannelWith 正常 resume 时 cancel，避免 Task 泄漏 + 多余日志
            leaveTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                if let c = self.leaveContinuation {
                    self.leaveContinuation = nil
                    c.resume()
                    AppLogger.party.notice("[PartyRTC] leave 500ms timeout, fallback resume")
                }
            }
        }
        // 正常 resume 后清 timeout task 句柄（didLeaveChannelWith 路径也会清，二层兜底）
        leaveTimeoutTask?.cancel()
        leaveTimeoutTask = nil

        engine.disableAudio()
        if wasVideoActive { engine.disableVideo() }  // 二轮复查：用快照避死分支（videoSeatActive 入口已置 false）
        // 二轮复查 wfpw5v1us（P2-9 加固）：delegate=nil 顺序前移到 releaseAllRemoteViews 之前
        // 防 unbindRemoteVideo → setupRemoteVideo(view:nil) 触发 SDK 回调进 Task 队列写已退场 state
        engine.delegate = nil
        // 清远端 view 池（spec v4 §5 R11 退进同房循环不残留）
        releaseAllRemoteViews()
        self.engine = nil
        state = .idle
        remoteUids = []
        remoteVolumes = [:]
        videoSeatActive = false
        updateFrameSnapshot()  // P0-1：engine=nil 后再刷新一次，快照彻底失效
        AppLogger.party.info("[PartyRTC] leave done")
    }
}

// MARK: - AgoraRtcEngineDelegate

extension PartyRTCEngine: AgoraRtcEngineDelegate {

    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinChannel channel: String, withUid uid: UInt, elapsed: Int) {
        AppLogger.party.info("[PartyRTC] didJoin ch=\(channel, privacy: .public) uid=\(uid, privacy: .public) elapsed=\(elapsed, privacy: .public)ms")
        // P1-4：weak self 避 SDK 回调 backlog 持有旧实例（D v5.3.2 同源）
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.state = .joined
            self.updateFrameSnapshot()  // P0-1：state 变更必须刷新快照
            self.delegate?.partyRTCEngineDidJoin(self)
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinedOfUid uid: UInt, elapsed: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.remoteUids.insert(uid)
            self.delegate?.partyRTCEngine(self, didJoinedRemoteUid: uid)
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOfflineOfUid uid: UInt, reason: AgoraUserOfflineReason) {
        Task { @MainActor [weak self] in
            guard let self else { return }
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
            // 二轮复查 wfpw5v1us：SDK 正常回调，cancel 500ms timeout Task（一层兜底，leave() await 后还有二层）
            self.leaveTimeoutTask?.cancel()
            self.leaveTimeoutTask = nil
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) {
        AppLogger.party.error("[PartyRTC] error code=\(errorCode.rawValue, privacy: .public)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.state == .joining {
                self.state = .failed("rtc_\(errorCode.rawValue)")
                self.updateFrameSnapshot()  // P0-1：state 变更
            }
            self.delegate?.partyRTCEngine(self, didFailWithReason: "rtc_\(errorCode.rawValue)")
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, connectionChangedTo state: AgoraConnectionState, reason: AgoraConnectionChangedReason) {
        AppLogger.party.notice("[PartyRTC] connection state=\(state.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        // 被踢 / 永久断开：通知 PartyStore（M4 内对接 forceLeaveRoom）
        if reason == .reasonBannedByServer {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.partyRTCEngine(self, didFailWithReason: "banned_by_server")
            }
        } else if reason == .reasonJoinFailed {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.partyRTCEngine(self, didFailWithReason: "join_failed")
            }
        }
    }

    /// v15 声波回调 → 派发 speakingUids（对齐 H5 `volumeList` + `PlayVolume` 说话反馈）。
    ///
    /// Agora 契约：
    /// - speakers 数组每 500ms 触发一次（enableAudioVolumeIndication interval）
    /// - volume 范围 0-255（官方标准），> 60 通用作"正在说话"阈值
    /// - **uid=0 代表本地用户**，需转换为 localAgoraUid 才能给 UI 层用 seat.userId 匹配
    /// - speakers 为空数组时 = 全体静音，需清空 speakingUids
    func rtcEngine(_ engine: AgoraRtcEngineKit, reportAudioVolumeIndicationOfSpeakers speakers: [AgoraRtcAudioVolumeInfo], totalVolume: Int) {
        // 阈值过滤 + uid=0 本地转换（Agora 官方阈值 ≥5，avoid 环境底噪 / 呼吸声误报）
        let localUid = localAgoraUid
        var uids = Set<UInt>()
        for info in speakers where info.volume > 5 {
            let mapped: UInt = info.uid == 0 ? localUid : UInt(info.uid)
            if mapped > 0 { uids.insert(mapped) }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.partyRTCEngine(self, didUpdateSpeakingUids: uids)
        }
    }
}

// MARK: - delegate 协议（PartyStore 实现）

@MainActor
protocol PartyRTCEngineDelegate: AnyObject {
    func partyRTCEngineDidJoin(_ engine: PartyRTCEngine)
    func partyRTCEngine(_ engine: PartyRTCEngine, didJoinedRemoteUid uid: UInt)
    func partyRTCEngine(_ engine: PartyRTCEngine, didOfflineRemoteUid uid: UInt)
    func partyRTCEngine(_ engine: PartyRTCEngine, didFailWithReason reason: String)
    /// v15 声纹反馈：正在说话的 uid 集合（500ms 一次全量替换，空集合=全静音）
    func partyRTCEngine(_ engine: PartyRTCEngine, didUpdateSpeakingUids uids: Set<UInt>)
}

// v15：给非声纹感知的实现方兜底空实现（PartyStore 会真实现，其他 delegate 无需强制）
extension PartyRTCEngineDelegate {
    func partyRTCEngine(_ engine: PartyRTCEngine, didUpdateSpeakingUids uids: Set<UInt>) {}
}
