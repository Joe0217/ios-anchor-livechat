import Foundation
import SwiftUI
import Combine
import Network

// MARK: - D 里程碑：CallStore 状态变化观察者协议
//
// 设计目的：CallStore.state 变化通知外部（如 LiveStore），实现单向回调，CallStore 不引用 LiveStore 类型。
// 典型实现：LiveStore conform 此协议，监听 connected/connecting → ended 后启动 resumeCall 15s 倒计时。
@MainActor
protocol CallStoreObserver: AnyObject {
    func callStore(_ store: CallStore, stateDidChange newState: CallState, previous: CallState)
}

/// 1v1 通话单层状态机（合并 H5 CallStateType + callGameStatus，采纳安卓 SDK 风格）。
///
/// 责任：
/// - 维护 `state` 和 `current`，把"按钮点击 / RTM 信令 / 计时器"统一收敛
/// - 主/被叫两条主流程的串行编排
/// - RTC 建链交给 AgoraManager；信令交给 CallSignaling；接口交给 CallService
///
/// 信令协议与 H5 声网 CallAPI `ICallMessage` 严格对齐：
/// 主叫端 `callOut` 生成 callId（UUID），整轮通话共享；被叫端从 `CallMessage.callId` 读出存下来，
/// 后续 accept/reject/hangup 时都要把同一个 callId 带回去。channelId 在主叫端来自 createCall，
/// 在被叫端来自 `CallMessage.fromRoomId`（主叫 RTC channel）。
@MainActor
final class CallStore: ObservableObject {
    static let shared = CallStore()

    // MARK: - 对外状态

    @Published private(set) var state: CallState = .idle {
        // D 里程碑：state 变化通知 observer（LiveStore 监听 connected/connecting → ended 触发 resumeCall）。
        // didSet 在 @Published publish 之后调用，满足 SwiftUI 渲染先于业务回调的顺序。
        didSet {
            guard oldValue != state else { return }
            observer?.callStore(self, stateDidChange: state, previous: oldValue)
        }
    }
    @Published private(set) var current: CurrentCallInfo = CurrentCallInfo()
    @Published private(set) var lastError: String = ""
    /// RTM client 是否已 login（永真直到 stop）。语义：login 已建立 → 信令通道存在。
    /// **注意**：不等于"RTM 连接当前可用"——断网/重连中时仍为 true。UI 用 `rtmConnectionState` 判定实时连接态。
    @Published private(set) var isSignalingReady: Bool = false
    /// RTM 实时连接状态（镜像 RtmReconnect.state，由 SDK connectionChangedToState 驱动）。
    /// HomeView 用此字段显示"已就绪/重连中/断连"。
    @Published private(set) var rtmConnectionState: RtmConnState = .idle

    /// RTC 管理器（CallView 用它做远端渲染 + push 美颜后的帧）
    let agora = AgoraManager()

    // MARK: - 内部

    private var signaling: CallSignaling?
    private var myUserId: Int = 0
    private var callOutTimeoutTask: Task<Void, Never>?
    /// ended → idle 的延迟切换 task。被 stop()/新 callOut 触发时必须 cancel，否则会异步把
    /// 已经被新通话覆盖的 state 重置回 .idle。
    private var endedToIdleTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// RTM 状态订阅句柄。CallStore 是单例 stop/start 可反复调用，订阅必须独立管理避免累积。
    private var rtmStateCancellable: AnyCancellable?
    /// 网络可达性监听器。冷启动无网→有网时自动 retry start。
    private var nwMonitor: NWPathMonitor?
    /// start 失败的 5s 兜底重试 task（即便无网络变化事件也能爬出来）。
    private var startRetryTask: Task<Void, Never>?
    /// 网络是否可达（NWPathMonitor 回调更新；用于避开"无网时还做 5s 重试"的浪费）。
    /// 初值 false：保守假设——冷启动时 NWPathMonitor 还未首次回调，按"无网"判定走 10s 兜底
    /// 节奏，等首次回调后再切换。避免 start 失败首次重试用 5s 触发又一次浪费。
    private var isNetworkAvailable: Bool = false
    /// start 防重入标志。start 是 async 含多个 await 点（getAgoraRtmToken / login）；
    /// NWPathMonitor、startRetryTask、RootView 都会触发 start，必须串行化避免双 CallSignaling
    /// 实例 + 双 RTM client 泄漏。
    private var isStarting: Bool = false
    /// callRate 上报开关（C 范围默认关，避免与后端联调相互干扰）
    // D 里程碑：callRate 上报开启（C 验证通过 + 后端契约确认 callRate 接口已上线）
    private var callRateEnabled = true

    /// D 里程碑：LiveStore weak 引用（对齐 AgoraManager.liveStore 模式）。
    /// 注入时机：LiveRoomView.onAppear 或 RootView 直播态分支；解绑：LiveRoomView 销毁。
    /// 用途：handleIncomingVideoCall 内判定 .living 时委托 LiveStore.pauseForCall 走直播私 call 流程。
    weak var liveStore: LiveStore?

    /// D 里程碑：状态变化观察者（CallStoreObserver 协议 T4）。
    /// LiveStore 在 RootView/LiveRoomView 注入时挂载，监听 connected/connecting → ended/idle 触发 resumeCall。
    weak var observer: CallStoreObserver?

    private init() {
        // 远端用户加入 RTC channel 时 → state 切 .connected（声网 didJoinedOfUid 触发）
        // 远端用户离开 → 兜底切 ended（一般已被 RTM hangup 提前处理，这里只防消息丢失）
        agora.$remoteUid
            .receive(on: DispatchQueue.main)
            .sink { [weak self] uid in
                guard let self else { return }
                Task { @MainActor in await self.handleRemoteRtcChange(uid: uid) }
            }
            .store(in: &cancellables)
    }

    /// 远端 RTC 状态变化 → state 升级 / 兜底挂断。
    ///
    /// ⚠️ 关键设计：必须 state == .connecting 才升级到 .connected，**不能从 .calling 直接升**。
    /// 原因：用户端实现是"收到 VideoCall 立即 RTC join（占位/订阅模式，等用户点接听后才推流）"，
    /// 如果在 .calling 时看到远端 join 就切 .connected，会出现"对端没接听但主播 UI 已是 FaceTime"
    /// 的灵异现象。.connecting 必须由对端 Accept 信令显式触发（handleRemoteAccept）。
    private func handleRemoteRtcChange(uid: UInt) async {
        if uid != 0 {
            guard state == .connecting else {
                print("📍 [CallStore] 远端 uid=\(uid) 加入但本端 state=\(state.rawValue)，等待 Accept 信令")
                return
            }
            current.callConnectTime = Date().timeIntervalSince1970 * 1000
            state = .connected
            print("✅ [CallStore] 远端 uid=\(uid) 加入 + 已收 Accept → state=connected")
        } else {
            // 远端离开：仅在通话中兜底（一般已被对端 hangup 信令提前处理）
            guard state == .connected else { return }
            print("⚠️ [CallStore] 远端离开 RTC（兜底挂断）")
            await endLocally(reason: .remoteHangUp, rateCategory: nil, rateType: .caller, abnormal: 0)
        }
    }

    // MARK: - 生命周期

    /// 登录后由 RootView 调用：拉 rtmToken，初始化 RTM client。
    /// 重复调用安全（已就绪直接 return）。
    /// **失败兜底**：① NWPathMonitor 监听网络恢复立刻 retry ② 5s 定时兜底 retry（即便无网络事件）。
    func start(myUserId: Int) async {
        if isSignalingReady { return }
        // 防重入：start 有 2 个 await 点（getAgoraRtmToken / login），NWPathMonitor 与
        // startRetryTask 任一进入会引发"双 CallSignaling 实例 + 双 RTM client"泄漏。
        if isStarting {
            print("⚠️ [CallStore] start 已在进行中，跳过 uid=\(myUserId)")
            return
        }
        isStarting = true
        defer { isStarting = false }

        self.myUserId = myUserId
        // 首次进入 start 时启动网络监听（一次性，stop 才销毁）
        if nwMonitor == nil { startNetworkMonitor() }
        do {
            let tokenRes = try await LiveService.getAgoraRtmToken()
            guard let rtm = tokenRes.rtmToken, !rtm.isEmpty else {
                lastError = "RTM token 为空"
                scheduleStartRetry(myUserId: myUserId, reason: "empty_token")
                return
            }
            let s = CallSignaling(myUserId: myUserId)
            s.delegate = self
            try await s.login(token: rtm, refreshToken: { [weak self] in
                guard self != nil else { return nil }
                return try? await LiveService.getAgoraRtmToken().rtmToken
            })
            signaling = s
            isSignalingReady = true
            lastError = ""
            cancelStartRetry()  // 成功后取消兜底 retry
            // 订阅 RTM 实时连接状态：login 成功后 reconnect.bind 已设 .connected，
            // 后续 SDK connectionChangedToState 回调驱动 .reconnecting/.disconnected/.connected 变化。
            rtmStateCancellable = s.rtmStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] new in
                    guard let self else { return }
                    if self.rtmConnectionState != new {
                        print("📡 [CallStore] rtmConnectionState \(self.rtmConnectionState.rawValue) → \(new.rawValue)")
                    }
                    self.rtmConnectionState = new
                }
            print("✅ [CallStore] start 成功 uid=\(myUserId)")
        } catch let e as APIError {
            lastError = "CallStore.start 失败: \(e.message)(\(e.code))"
            print("❌ [CallStore] \(lastError)")
            scheduleStartRetry(myUserId: myUserId, reason: "api_\(e.code)")
        } catch {
            lastError = "CallStore.start 异常: \(error.localizedDescription)"
            print("❌ [CallStore] \(lastError)")
            scheduleStartRetry(myUserId: myUserId, reason: "exception")
        }
    }

    // MARK: - start 失败兜底重试

    /// 调度 5s 后再 try start。若期间网络恢复（NWPathMonitor 触发），会被 cancel 由网络回调立刻 retry。
    private func scheduleStartRetry(myUserId: Int, reason: String) {
        cancelStartRetry()
        let delay: TimeInterval = isNetworkAvailable ? 5 : 10  // 无网络时等长一点，省电
        print("🔄 [CallStore] scheduleStartRetry reason=\(reason) delay=\(delay)s (net=\(isNetworkAvailable))")
        startRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self, !self.isSignalingReady, self.myUserId == myUserId else { return }
            await self.start(myUserId: myUserId)
        }
    }

    private func cancelStartRetry() {
        startRetryTask?.cancel()
        startRetryTask = nil
    }

    // MARK: - 网络可达性监听（NWPathMonitor）

    /// 监听网络可达性，从 unsatisfied → satisfied 时若 RTM 未就绪则立即 retry start。
    /// 解决"冷启动无网 → 用户开网后 RTM 永远停在 idle"的死锁。
    private func startNetworkMonitor() {
        let m = NWPathMonitor()
        // NWPathMonitor.start 后会立即首次回调当前实际网络状态。初值 isNetworkAvailable=false
        // 与"网络恢复"边沿（was=false → satisfied=true）匹配，会触发一次不必要的 retry 调度
        // （isStarting 守卫挡住但产生噪音日志）。用 firstCallback flag 跳过首次仅同步初值。
        var isFirstCallback = true
        m.pathUpdateHandler = { [weak self] path in
            let satisfied = (path.status == .satisfied)
            let firstShot = isFirstCallback
            isFirstCallback = false
            Task { @MainActor [weak self] in
                guard let self else { return }
                let was = self.isNetworkAvailable
                self.isNetworkAvailable = satisfied
                if firstShot {
                    print("📶 [CallStore] NWPathMonitor 首次回调 satisfied=\(satisfied)（仅同步初值）")
                    return
                }
                if !was && satisfied {
                    if !self.isSignalingReady, self.myUserId != 0 {
                        // 冷启动失败 → 立即 retry start（已 login 之前的路径）
                        print("📶 [CallStore] 网络恢复 → 立即 retry start uid=\(self.myUserId)")
                        self.cancelStartRetry()
                        await self.start(myUserId: self.myUserId)
                    } else if self.isSignalingReady, let s = self.signaling {
                        // 已 login → 通知 RtmReconnect 立即重连（消除慢重试 5s tick 等待）
                        print("📶 [CallStore] 网络恢复 → 通知 RTM 立即重连")
                        s.notifyNetworkResumed(reason: "network_resume")
                    } else {
                        print("📶 [CallStore] 网络恢复（未登录，忽略）")
                    }
                } else if was && !satisfied {
                    print("📶 [CallStore] 网络断开 status=\(path.status)")
                }
            }
        }
        // Apple 文档推荐用专用 queue 避免回调被其他全局任务阻塞。qos 选 .userInitiated：
        // 网络变化是用户感知事件，闭包应尽快被调度（vs .utility 偏后台）。
        m.start(queue: DispatchQueue(label: "com.anchor.livechat.nwpath", qos: .userInitiated))
        nwMonitor = m
        print("📶 [CallStore] NWPathMonitor 已启动")
    }

    /// 登出时清理 RTM + RTC + 状态。
    func stop() {
        cancelCallOutTimeout()
        cancelStartRetry()
        nwMonitor?.cancel()
        nwMonitor = nil
        endedToIdleTask?.cancel()
        endedToIdleTask = nil
        rtmStateCancellable?.cancel()
        rtmStateCancellable = nil
        if state != .idle { agora.leave() }
        signaling?.logout()
        signaling = nil
        isSignalingReady = false
        rtmConnectionState = .idle
        myUserId = 0
        state = .idle
        current = CurrentCallInfo()
    }

    // MARK: - 主叫：拨号
    //
    // 严格对齐 H5 主播端 useCallApi.handleCallOutFunc + callApi.call：
    //   1) await apiCreateCall(beCallUserId, callType) → 拿后端真 channelId + 对方资料
    //      （fromRoomId 必须是后端真实 channelId，否则用户端 apiJoinCall 查不到 → 浮层闪一下消失）
    //   2) 端侧 UUID 生成 callId
    //   3) _autoCancelCall(true) 启动 30s 超时
    //   4) _rtcJoinAndPublish() —— 不 await，与 publish 并发
    //   5) await _publishMessage({action=videoCall, fromRoomId=后端channelId})
    //
    // 1111 错误 "current status unable to make a call" 不是"主播角色被禁"，是 WSHeartbeat
    // 上报的 onlineStatus 错误。后端要求 CALL_END(10001) 才放行 createCall；FOREGROUND(10002)
    // 被拒。已在 WSHeartbeat 调整为 .callEnd。
    func callOut(remoteUserId: String) async {
        guard state == .idle, let signaling else {
            print("⚠️ [CallStore] callOut 跳过 state=\(state) signaling=\(signaling != nil)")
            return
        }
        guard let remoteUid = Int(remoteUserId), remoteUid > 0 else {
            lastError = "对方 userId 非法"
            return
        }

        // 1) 调 createCall 拿后端真 channelId + 对方资料
        let res: CreateCallResult
        do {
            res = try await CallService.createCall(beCallUserId: remoteUid)
        } catch let e as APIError {
            lastError = e.message
            print("❌ [CallStore] createCall 失败 code=\(e.code) msg=\(e.message)")
            return
        } catch {
            lastError = error.localizedDescription
            return
        }
        guard let channelId = res.channelId, !channelId.isEmpty else {
            lastError = "createCall 返回空 channelId"
            return
        }

        // 2) 初始化 currentCallInfo（含 createCall 返回的对方资料）
        var info = CurrentCallInfo()
        info.frontGameType = .direct
        info.inOrOut = .out
        info.channelId = channelId                   // 后端真 channelId = fromRoomId
        info.callId = UUID().uuidString              // 端侧 UUID（H5 _callMessage.setCallId 等价）
        info.remoteUserId = remoteUid
        info.remoteYxAccid = res.yxAccid ?? ""
        info.remoteNickname = res.nickname ?? ""
        info.remoteIcon = res.icon ?? ""
        info.remoteAge = res.age ?? 0
        info.remoteCountryCode = res.countryCode ?? ""
        info.remoteVideoPrice = res.videoPrice ?? 0
        info.callStartTime = Date().timeIntervalSince1970 * 1000
        current = info
        state = .calling

        // 3) 启动 30s 超时（H5 _autoCancelCall(true)）
        startCallOutTimeout()

        // 4) 主叫立刻 join 自己一侧 RTC（H5 _rtcJoinAndPublish 不 await）
        let channelToJoin = info.channelId
        Task { @MainActor [weak self] in
            await self?.joinRtc(channel: channelToJoin, rateType: .caller)
        }

        // 5) 发 RTM VideoCall（H5 await _publishMessage）
        let ok = await signaling.publish(buildMessage(action: .videoCall))
        if !ok {
            lastError = "发送呼叫失败"
            await endLocally(reason: .beginCallError, rateCategory: .canceled, rateType: .caller, abnormal: 1)
            return
        }
    }

    // MARK: - 主叫：取消（未接通前用户主动撤回）

    func cancel() async {
        guard state == .calling, current.inOrOut == .out else { return }
        cancelCallOutTimeout()
        if let signaling {
            _ = await signaling.publish(buildMessage(action: .cancel))
        }
        await endLocally(reason: .localHangUp, rateCategory: .canceled, rateType: .caller, abnormal: 0)
    }

    // MARK: - 被叫：接受 / 拒绝

    /// D 里程碑：直播态私 call 自动接听入口。
    /// 由 LiveStore.pauseForCall 调用，不弹浮层、无 UI 确认；frontGameType 写入 .live 标记本通通话来源。
    ///
    /// 与 `accept()` 的差异：
    /// - 不依赖现有 `state == .calling`（直接从 .idle 起步）
    /// - 跳过弹浮层等候用户操作的 calling 中间态视觉环节
    /// - 显式标记 `frontGameType = .live`，CallView UI 据此显示"直播私 call"标识 + "挂断回直播"
    func acceptIncomingFromLive(msg: CallMessage) async {
        guard state == .idle, let signaling else {
            print("⚠️ [CallStore] acceptIncomingFromLive 跳过 state=\(state) signaling=\(signaling != nil)")
            return
        }
        guard let fromRoomId = msg.fromRoomId, !fromRoomId.isEmpty else {
            print("⚠️ [CallStore] acceptIncomingFromLive 缺 fromRoomId")
            return
        }

        // 1) 初始化 currentCallInfo（被叫 in / frontGameType=.live）
        var info = CurrentCallInfo()
        info.frontGameType = .live
        info.inOrOut = .in
        info.channelId = fromRoomId
        info.callId = msg.callId
        info.remoteUserId = msg.fromUserId
        info.callStartTime = Date().timeIntervalSince1970 * 1000
        current = info
        state = .calling

        // 2) 立刻发 Accept（publish 失败必须收尾，避免主叫永等不到 Accept）
        let ok = await signaling.publish(buildMessage(action: .accept))
        guard ok else {
            lastError = "私 call 发送接听失败"
            await endLocally(reason: .beginCallError, rateCategory: nil, rateType: .callee, abnormal: 1)
            return
        }
        state = .connecting

        // 3) join RTC 通话频道
        await joinRtc(channel: fromRoomId, rateType: .callee)

        // 4) 主叫端可能已在频道（callOut 时先 join），若 didJoinedOfUid 在切到 .connecting 前已触发，
        //    handleRemoteRtcChange 不会再回调，此处手动补一次升级。
        if agora.remoteUid != 0, state == .connecting {
            current.callConnectTime = Date().timeIntervalSince1970 * 1000
            state = .connected
            print("✅ [CallStore] 直播私 call 接听后远端已在频道 → state=connected")
        }

        // 5) 异步拉对方资料（C 范围 joinCall 接口；失败仅影响 UI，不影响接通能力）
        Task { @MainActor in
            do {
                let r = try await CallService.joinCall(channelId: fromRoomId)
                guard self.state != .idle, self.current.callId == msg.callId else { return }
                self.current.remoteYxAccid = r.yxAccid ?? self.current.remoteYxAccid
                self.current.remoteNickname = r.nickname ?? self.current.remoteNickname
                self.current.remoteIcon = r.icon ?? self.current.remoteIcon
                self.current.remoteAge = r.age ?? self.current.remoteAge
                self.current.remoteCountryCode = r.countryCode ?? self.current.remoteCountryCode
                self.current.remoteVideoPrice = r.videoPrice ?? self.current.remoteVideoPrice
            } catch {
                print("⚠️ [CallStore] LIVE joinCall 拉对方资料失败 channel=\(fromRoomId) err=\(error.localizedDescription)")
            }
        }
    }

    /// 被叫接受通话。
    func accept(auto: Bool = false) async {
        guard state == .calling, current.inOrOut == .in, let signaling else { return }
        let info = current

        // 1) 通知主叫 —— 必须成功才能前进
        //    ⚠️ publish 失败时**不切 .connecting**：否则主叫永远收不到 Accept、30s 后发
        //    Cancel，本端此时是 .connecting，handleRemoteCancel 守卫 `state == .calling`
        //    会丢 Cancel → 卡死 .connecting。
        let ok = await signaling.publish(buildMessage(action: .accept))
        guard ok else {
            lastError = "发送接听失败"
            await endLocally(reason: .beginCallError, rateCategory: nil, rateType: .callee, abnormal: 1)
            return
        }
        state = .connecting

        // 2) 拿 rtcToken + join 频道
        await joinRtc(channel: info.channelId, rateType: .callee)

        // 3) 主叫端可能已经在频道里（主叫 callOut 时先 join），如此 didJoinedOfUid
        //    在状态切到 .connecting 之前就触发过、不会再触发，这里手动补一次升级。
        if agora.remoteUid != 0, state == .connecting {
            current.callConnectTime = Date().timeIntervalSince1970 * 1000
            state = .connected
            print("✅ [CallStore] accept 后远端已在频道 → state=connected")
        }

        // 4) 接通率上报（被叫 answered）
        await reportRate(category: .answered, type: .callee, answerTime: info.sinceStartDuration, abnormal: 0)
    }

    /// 被叫拒绝通话。
    func reject() async {
        guard state == .calling, current.inOrOut == .in, let signaling else { return }
        _ = await signaling.publish(buildMessage(action: .reject))
        await endLocally(reason: .localHangUp, rateCategory: .rejected, rateType: .callee, abnormal: 0)
    }

    // MARK: - 接通后：挂断

    /// 通话中本地挂断。
    func hangup() async {
        guard state == .connecting || state == .connected else { return }
        if let signaling {
            _ = await signaling.publish(buildMessage(action: .hangup))
        }
        await endLocally(reason: .localHangUp, rateCategory: nil, rateType: .caller, abnormal: 0)
    }

    // MARK: - 内部：构造 CallMessage

    /// 严格对齐 H5 callApi/core/callApi.ts 各 action 的 publish payload：
    /// - VideoCall: 带 fromRoomId（被叫据此 join 同频道）
    /// - Cancel:    带 cancelCallByInternal=0（External，用户主动取消）
    /// - Reject:    带 rejectReason + rejectByInternal=0（External）
    /// - Accept / Hangup: 不带额外字段
    /// callId / fromUserId / remoteUserId 是所有 action 通用必填，由 CryptoJS encode 自动塞，
    /// 这里对齐到 Swift Codable init 显式传。
    private func buildMessage(action: CallAction, rejectReason: String? = nil) -> CallMessage {
        switch action {
        case .videoCall, .audioCall:
            return CallMessage(action: action,
                               fromUserId: myUserId,
                               remoteUserId: current.remoteUserId,
                               callId: current.callId,
                               fromRoomId: current.channelId)
        case .cancel:
            return CallMessage(action: action,
                               fromUserId: myUserId,
                               remoteUserId: current.remoteUserId,
                               callId: current.callId,
                               cancelCallByInternal: 0)
        case .reject:
            return CallMessage(action: action,
                               fromUserId: myUserId,
                               remoteUserId: current.remoteUserId,
                               callId: current.callId,
                               rejectReason: rejectReason,
                               rejectByInternal: 0)
        case .accept, .hangup:
            return CallMessage(action: action,
                               fromUserId: myUserId,
                               remoteUserId: current.remoteUserId,
                               callId: current.callId)
        }
    }

    // MARK: - 内部：RTC 建链
    //
    // 本端 join channel 完成后 state 不切 .connected——必须等远端 didJoinedOfUid 回调
    // （即对方真正 join 同一 channel）才算接通；状态升级在 handleRemoteRtcChange 里做。
    //
    // ⚠️ joinRtc 内有 `await getAgoraRtmToken`（网络），期间对端可能 Hangup → endLocally 先跑、
    // state=.ended、agora 已 leave。如果 token 拿回后无脑 agora.join，会创建一个游离的 RTC 通道
    // 没有清理路径。所以拿到 token 后必须再次校验 state 仍处于"应当继续 join"的阶段。
    private func joinRtc(channel: String, rateType: CallRateType) async {
        let stateBeforeAwait = state
        do {
            let tokenRes = try await LiveService.getAgoraRtmToken()
            guard let rtcToken = tokenRes.rtcToken, !rtcToken.isEmpty else {
                lastError = "获取 rtcToken 失败"
                await endLocally(reason: .beginCallError, rateCategory: nil, rateType: rateType, abnormal: 1)
                return
            }
            // 关键守卫：state 必须仍在拨号/接通过程中。.calling 适用于主叫端 callOut 后立刻 join 的
            // 路径；.connecting 适用于主/被叫 Accept 后的路径。其它（.ended/.failed/.idle）都
            // 表示通话已中止，幽灵 join 必须被阻断。
            guard state == .calling || state == .connecting else {
                print("📍 [CallStore] joinRtc 拿到 token 后 state 已是 \(state.rawValue)（之前=\(stateBeforeAwait.rawValue)）→ 放弃 join")
                return
            }
            agora.join(channelId: channel, token: rtcToken, uid: UInt(myUserId), profile: .communication)
        } catch let e as APIError {
            lastError = "rtcToken: \(e.message)"
            await endLocally(reason: .beginCallError, rateCategory: nil, rateType: rateType, abnormal: 1)
        } catch {
            lastError = "rtcToken: \(error.localizedDescription)"
            await endLocally(reason: .beginCallError, rateCategory: nil, rateType: rateType, abnormal: 1)
        }
    }

    // MARK: - 内部：统一收尾

    private func endLocally(reason: CallOverReason,
                            rateCategory: CallRateCategory?,
                            rateType: CallRateType,
                            abnormal: Int) async {
        cancelCallOutTimeout()
        let info = current
        current.hangupReason = reason
        if state != .idle { agora.leave() }
        // ⚠️ 主播端**不调** `/callOver`（后端无此路由 → 404；该接口是用户端独有的，后端按
        // 用户端 callOver 触发结算）。本端只做 RTC leave + 状态复位 + callRate（可选）。
        if !info.channelId.isEmpty, let cat = rateCategory {
            await reportRate(category: cat, type: rateType,
                             answerTime: info.connectedDuration > 0 ? info.connectedDuration : info.sinceStartDuration,
                             abnormal: abnormal)
        }
        state = .ended
        scheduleEndedToIdle()
    }

    /// ended → idle 的延迟 500ms 切换（让 UI 有时间播完"已挂断"提示）。
    /// 使用可取消的 Task：stop() / 新 callOut 触发时必须 cancel，否则会异步把已被新通话
    /// 占用的 state 错误复位回 idle。
    private func scheduleEndedToIdle() {
        endedToIdleTask?.cancel()
        endedToIdleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled, self.state == .ended else { return }
            self.state = .idle
            self.current = CurrentCallInfo()
        }
    }

    private func reportRate(category: CallRateCategory, type: CallRateType,
                            answerTime: Int, abnormal: Int) async {
        guard callRateEnabled, !current.channelId.isEmpty else { return }
        await CallService.callRate(
            channelId: current.channelId,
            callType: type, category: category,
            answerTime: answerTime, userType: .anchor, abnormal: abnormal
        )
    }

    // MARK: - 内部：主叫超时

    private func startCallOutTimeout() {
        cancelCallOutTimeout()
        callOutTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CallTuning.callOutTimeoutSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard self.state == .calling, self.current.inOrOut == .out else { return }
            print("⏰ [CallStore] 主叫 30s 超时无应答 → 自动取消")
            if let signaling = self.signaling {
                _ = await signaling.publish(self.buildMessage(action: .cancel))
            }
            await self.endLocally(reason: .userConcurrentCancel, rateCategory: .timeout, rateType: .caller, abnormal: 0)
        }
    }

    private func cancelCallOutTimeout() {
        callOutTimeoutTask?.cancel()
        callOutTimeoutTask = nil
    }
}

// MARK: - CallSignalingDelegate（处理对端 RTM 信令）

extension CallStore: CallSignalingDelegate {
    func signaling(_ signaling: CallSignaling, didReceive message: CallMessage, from publisher: String) {
        guard let action = message.action else {
            print("⚠️ [CallStore] 未知 action=\(message.messageAction) from=\(publisher)")
            return
        }
        Task { @MainActor in await self.handleRemote(action: action, message: message) }
    }

    func signalingDidDetectSameUidLogin(_ signaling: CallSignaling) {
        print("🚨 [CallStore] 同 UID 登录 — 主流程交给 SessionStore.logout")
        Task { @MainActor in SessionStore.shared.logout() }
    }

    private func handleRemote(action: CallAction, message msg: CallMessage) async {
        switch action {
        case .videoCall:   await handleIncomingVideoCall(msg)
        case .audioCall:   print("⚠️ [CallStore] 收到 audioCall（C 不接入）from=\(msg.fromUserId)")
        case .cancel:      await handleRemoteCancel(msg)
        case .accept:      await handleRemoteAccept(msg)
        case .reject:      await handleRemoteReject(msg)
        case .hangup:      await handleRemoteHangup(msg)
        }
    }

    private func handleIncomingVideoCall(_ msg: CallMessage) async {
        // 校验是发给本端的
        guard msg.remoteUserId == myUserId else {
            print("⚠️ [CallStore] 来电 remoteUserId(\(msg.remoteUserId)) 与本端(\(myUserId)) 不符，忽略")
            return
        }
        // D 里程碑：直播态优先走"直播私 call 自动接听"分支（不弹浮层、无 UI 确认）
        // 协议保证：用户端在直播间内发起的拨打都视为直播私 call，无需在 RTM 协议层区分类型
        // weak liveStore 由 LiveRoomView/RootView 在直播态注入（对齐 AgoraManager.liveStore 模式）
        if let ls = liveStore, ls.state == .living, ls.callState == 0 {
            print("📞 [CallStore] 直播态收到私 call → 委托 LiveStore.pauseForCall")
            await ls.pauseForCall(msg: msg)
            return
        }
        guard state == .idle else {
            print("⚠️ [CallStore] 收到来电但本端非 idle（state=\(state)）→ 自动忙线拒绝")
            if let signaling {
                // H5 callApi.ts:813 _autoReject 用 rejectByInternal=Internal(1) + reason="busy"，
                // 不带 fromRoomId（Reject payload 与 H5 严格对齐）。
                let busy = CallMessage(action: .reject,
                                       fromUserId: myUserId,
                                       remoteUserId: msg.fromUserId,
                                       callId: msg.callId,
                                       rejectReason: "busy",
                                       rejectByInternal: 1)
                _ = await signaling.publish(busy)
            }
            return
        }

        // VideoCall 必须带 fromRoomId（被叫据此 join），缺则视为非法消息丢弃
        guard let fromRoomId = msg.fromRoomId, !fromRoomId.isEmpty else {
            print("⚠️ [CallStore] VideoCall 缺 fromRoomId from=\(msg.fromUserId) 丢弃")
            return
        }

        var info = CurrentCallInfo()
        info.frontGameType = .direct
        info.inOrOut = .in
        info.channelId = fromRoomId              // ⚠️ 被叫端 channelId 来自 fromRoomId
        info.callId = msg.callId                 // ⚠️ 整轮通话沿用主叫生成的 callId
        info.remoteUserId = msg.fromUserId
        info.callStartTime = Date().timeIntervalSince1970 * 1000
        current = info
        state = .calling

        // 3s 超时拉对方资料（失败仅影响 UI 展示，不影响接通能力）
        Task { @MainActor in
            do {
                let r = try await CallService.joinCall(channelId: fromRoomId)
                guard self.state == .calling, self.current.inOrOut == .in,
                      self.current.channelId == fromRoomId else { return }
                self.current.remoteYxAccid = r.yxAccid ?? self.current.remoteYxAccid
                self.current.remoteNickname = r.nickname ?? self.current.remoteNickname
                self.current.remoteIcon = r.icon ?? self.current.remoteIcon
                self.current.remoteAge = r.age ?? self.current.remoteAge
                self.current.remoteCountryCode = r.countryCode ?? self.current.remoteCountryCode
                self.current.remoteVideoPrice = r.videoPrice ?? self.current.remoteVideoPrice
            } catch {
                print("⚠️ [CallStore] joinCall 拉对方资料失败/超时 channel=\(fromRoomId) err=\(error.localizedDescription)")
            }
        }
    }

    private func handleRemoteCancel(_ msg: CallMessage) async {
        guard state == .calling, current.callId == msg.callId else { return }
        // H5 CALL_OVER_REASON_NUMBER 没有"远端取消"独立码，沿用 2 (remoteHangUp) 是历史选择。
        await endLocally(reason: .remoteHangUp, rateCategory: .canceled, rateType: .callee, abnormal: 0)
    }

    private func handleRemoteAccept(_ msg: CallMessage) async {
        guard state == .calling, current.inOrOut == .out, current.callId == msg.callId else { return }
        cancelCallOutTimeout()
        state = .connecting
        await joinRtc(channel: current.channelId, rateType: .caller)
        // 主叫 callOut 时已 RTC join，若远端已先到（didJoinedOfUid 在 .calling 被门控），手动补升级
        if agora.remoteUid != 0, state == .connecting {
            current.callConnectTime = Date().timeIntervalSince1970 * 1000
            state = .connected
            print("✅ [CallStore] 主叫收 Accept 后远端已在频道 → state=connected")
        }
    }

    private func handleRemoteReject(_ msg: CallMessage) async {
        guard state == .calling, current.inOrOut == .out, current.callId == msg.callId else { return }
        lastError = "对方已拒绝"
        await endLocally(reason: .remoteHangUp, rateCategory: .rejected, rateType: .caller, abnormal: 0)
    }

    private func handleRemoteHangup(_ msg: CallMessage) async {
        guard state == .connecting || state == .connected, current.callId == msg.callId else { return }
        await endLocally(reason: .remoteHangUp, rateCategory: nil, rateType: .caller, abnormal: 0)
    }
}
