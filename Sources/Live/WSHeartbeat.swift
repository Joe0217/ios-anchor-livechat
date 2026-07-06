import Foundation
import UIKit
import os

/// 主播在线态 WebSocket 心跳（对应安卓 `VptWebSocketManager` + 后端 `weidou-socket`）。
///
/// **这是用户端"看到主播在线"的唯一来源**——后端按 WS 长连接 + 周期心跳里的 `onlineStatus`
/// 维护 `onlineGroupStatus`。NIM 长连虽然必要（用于 IM 消息），但 dev 环境的"主播是否在线"
/// 列表字段由本通道驱动。
///
/// 协议（与安卓主播端严格对齐，照后端 `WebSocketOnlineUserConfig` 真值）：
/// - 握手 URL：`{socketBaseURL}/webSocket?ciphertext={AES_ECB_Hex({"appToken":<loginUuid>})}`
/// - **心跳间隔 15s**（对齐安卓 `VptWebSocketManager.java:43`；上限 `USER_PARTY_ROOM_STATUS` TTL 25s）
/// - **messageType = 1（REPORT_STATUS）**：唯一心跳类型；后端 `MyWebSocketHandler.java:77` 路由到
///   `reportStatusHandler(userType=2)` 写主播在线表 + **同时** `partyRoomHeartbeat()` 刷新派对键
/// - **expandParams 字段**：`{channelId, onlineStatus, roomId?, seatIndex?}` —— `roomId/seatIndex`
///   仅在派对房内有值时附；安卓用 Gson null 省略，iOS 同等价
/// - **30s 阈值踢下麦**（`PartyRoomSeatServiceImpl.java:626`，全员统一无主播豁免）
/// - 关键守卫：`partyRoomHeartbeat` 仅当 `roomId>0` 才刷新派对键（`WebSocketOnlineUserConfig.java:435`）
/// - onlineStatus 取值：1=ONLINE / 2=OFFLINE / 10000=CALLING / 10001=CALL_END /
///   10002=FOREGROUND / 10003=BACKGROUND
/// - 断线重连：5s/次（H5 是 720 次 ≈ 1h；iOS 简化为无上限直到 stop）
@MainActor
final class WSHeartbeat: NSObject, URLSessionWebSocketDelegate {
    static let shared = WSHeartbeat()

    /// LIVE_STATUS_NUMBER 子集（D 起扩到 5 个）
    enum OnlineStatus: Int {
        case offline    = 2
        case calling    = 10000     // 通话中（D 新增；对齐 H5 getOnlineStatus checkOnCall 分支）
        case callEnd    = 10001     // 通话结束 / 空闲在线（主状态 1）
        case foreground = 10002     // 前台（主状态 1）
        case background = 10003     // 后台（主状态 2）
    }

    @Published private(set) var connected: Bool = false

    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var loginUuid: String = ""
    private var disposed = true
    /// 心跳间隔。15s 对齐安卓主播端（`VptWebSocketManager.java:43`）；
    /// 后端 `USER_PARTY_ROOM_STATUS` TTL 25s + 麦位踢人 30s，间隔须 <25s。
    private let interval: TimeInterval = 15
    private let reconnectDelay: TimeInterval = 5

    /// 当前应发的"在线态"状态。startPing/前后台切换/重连握手首包统一读取此值，
    /// 由 `notifyCallStateChanged(callState:)` 改写，让通话状态变化能影响周期心跳值。
    /// 默认 `.callEnd`（空闲在线）。
    private var currentStatus: OnlineStatus = .callEnd

    /// 派对房上下文（安卓确认 + spec v3）：用户在派对房时 WS 心跳必须带 roomId（在麦上时再附 seatIndex），
    /// 后端 `partyRoomHeartbeat()` 据此写 `user:online:party:room[userId].lastActiveTime`，30s 阈值踢下麦。
    /// 由 `PartyStore.enterRoom/leaveRoom/postMikeList` 调用 `setPartyContext` 更新。
    private var partyRoomId: String = ""
    private var partySeatIndex: Int = -1   // >0 麦位号 1-13；其余视为不在麦上，省略字段（对齐安卓 Gson null 省略）

    private override init() {
        super.init()
        // delegate=self 用于诊断握手响应（拿 HTTP statusCode），nonisolated 回调内 hop 回 MainActor
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    // MARK: - 公开 API

    /// 登录后调用。重复调用安全（已就绪直接返回）。
    func start(loginUuid: String) {
        if task != nil { return }
        self.loginUuid = loginUuid
        disposed = false
        connect()
    }

    /// 登出时调用。会先发一条 OFFLINE 状态再断开。
    func stop() {
        disposed = true
        cancelPing()
        cancelReconnect()
        // best-effort 发一条 OFFLINE，让服务端立刻把状态切走
        sendStatus(.offline)
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        connected = false
    }

    // MARK: - 连接

    private func connect() {
        guard !disposed else { return }
        guard let url = buildHandshakeURL() else {
            AppLogger.heartbeat.notice("⚠️ [WS] 握手 URL 构造失败")
            return
        }
        let queryLen = (url.query?.count ?? 0)
        AppLogger.heartbeat.debug("📡 [WS] connecting host=\(url.host ?? "?", privacy: .public) path=\(url.path, privacy: .public) queryLen=\(queryLen, privacy: .public)")
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        startReceiveLoop()
        // 注：不再在此处立即 sendStatus / startPing / 置 connected=true。
        // task.resume() 只是异步提交连接请求，握手（TLS + HTTP 101）尚未完成，
        // 底层 socket 未 ready，立即 send 会命中 Darwin ENOTCONN (errno 57)
        // → sendStatus 内 send failure callback 触发 scheduleReconnect
        // → 5s 后又 connect → 又立即 send → **无限重连循环**（真机观察到 30+ 次 task 循环）。
        //
        // 正解：全部挪到 didOpenWithProtocol delegate（HTTP 101 到达信号）里，与握手成功对齐。
        //   - 首包 sendStatus(currentStatus) — 通话期 .calling / 空闲 .callEnd(10001)
        //     （对齐 H5 getOnlineStatus，不发 .foreground 避免后端 1111 拒绝 createCall）
        //   - startPing() — 15s 周期心跳，对齐安卓 VptWebSocketManager
    }

    /// `{base}/webSocket?ciphertext={AES_ECB_Hex(JSON({"appToken":uuid}))}`
    ///
    /// ⚠️ cipher 算法与主接口请求体**完全不同**：
    ///   - 主接口请求体：AES-128-CBC + key `9986sdff5s4f1123` + IV + Base64 输出
    ///   - WS 握手 cipher：AES-128-ECB + key `9976kk4322578894`（无 IV）+ Hex 输出
    /// 对应 H5 `src/utils/index.js:361` 的 `encryptAes(data)`。Hex 字符串只含 `0-9 a-f`，
    /// 没有 `+ / =` 那些 URL 歧义字符，因此无需 percent-encode。
    private func buildHandshakeURL() -> URL? {
        let body = ["appToken": loginUuid]
        guard let json = try? JSONSerialization.data(withJSONObject: body),
              let jsonStr = String(data: json, encoding: .utf8),
              let cipher = CryptoUtil.aesEncryptECBToHex(jsonStr) else {
            return nil
        }
        // 仅打 cipher 长度做诊断；不再泄露密文 prefix（AES-128-ECB 固定 key + 已知明文头部 `{"appT`
        // 重放风险，dev console privacy:.private 仍可见）。
        AppLogger.heartbeat.debug("📡 [WS] cipher(hex) len=\(cipher.count, privacy: .public)")
        return URL(string: "\(AppConfig.socketBaseURL)/webSocket?ciphertext=\(cipher)")
    }

    // MARK: - URLSessionWebSocketDelegate（拿 HTTP 响应诊断握手）

    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol p: String?) {
        AppLogger.heartbeat.debug("📡 [WS] didOpen protocol=\(p ?? "nil", privacy: .public)")
        // 真正握手成功（HTTP 101 Switching Protocols）才置 connected=true + 发首包 + 启 ping。
        // 之前在 connect() 里 t.resume() 后立即 send 会命中 errno 57 无限重连循环。
        Task { @MainActor [weak self] in
            guard let self, !self.disposed else { return }
            self.connected = true
            self.sendStatus(self.currentStatus)
            self.startPing()
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "<nil>"
        AppLogger.heartbeat.debug("📡 [WS] didClose code=\(closeCode.rawValue, privacy: .public) reason=\(reasonStr, privacy: .private)")
        // 与 didOpen 对称：服务端主动 close frame 时立即置 connected=false 触发重连，
        // 不用等 receive loop failure 分支（可能滞后）。审查报告-202607061703 必修-1。
        // 幂等：scheduleReconnect 内 cancelReconnect 自动去重与 receive loop 并发调用无副作用。
        Task { @MainActor [weak self] in
            guard let self, !self.disposed else { return }
            self.connected = false
            self.scheduleReconnect()
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        let resp = task.response as? HTTPURLResponse
        let body = (task as? URLSessionDataTask).flatMap { _ in "" } ?? ""
        AppLogger.heartbeat.debug("📡 [WS] task didComplete status=\(resp?.statusCode ?? -1, privacy: .public) err=\(error?.localizedDescription ?? "nil", privacy: .private) body=\(body, privacy: .private)")
        // 覆盖 TLS/DNS/HTTP 4xx 握手失败场景（didOpen 未 fire、receive loop 未启动 → 现有分支无人触发重连 → 卡死）。
        // 正常关闭 (stop 主动 close) 时 error=nil，前置守卫不触发重连；stop 内已 disposed=true 再兜底一层。
        guard error != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.disposed else { return }
            self.connected = false
            self.scheduleReconnect()
        }
    }

    // MARK: - 收 / 发

    private func startReceiveLoop() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .success:
                    // 服务端回应 messageType==1 = 心跳应答，不做业务处理
                    if !self.disposed { self.startReceiveLoop() }
                case .failure(let err):
                    AppLogger.heartbeat.debug("📡 [WS] receive 失败: \(err.localizedDescription, privacy: .private) → 调度重连")
                    self.connected = false
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func sendStatus(_ status: OnlineStatus, channelId: String = "") {
        // messageType=1（REPORT_STATUS）：后端 `MyWebSocketHandler.java:77` 路由到
        // `reportStatusHandler(userType=2)` 写主播在线表 + 同时 `partyRoomHeartbeat()` 刷新派对键。
        // 派对房上下文（roomId/seatIndex）走同一条 expandParams 注入；不发独立的 messageType=3
        // （H5 用户端那套用户级心跳是另一协议，安卓主播端只发 messageType=1 / 15s）。
        // 关键守卫：`partyRoomHeartbeat` 仅当 `roomId>0` 才刷新派对键（`WebSocketOnlineUserConfig.java:435`）。
        var expand: [String: Any] = [
            "channelId": channelId,
            "onlineStatus": status.rawValue,
        ]
        if !partyRoomId.isEmpty {
            expand["roomId"] = partyRoomId
            // 仅在麦上才带 seatIndex（>0 1-13 麦位号）；不在麦时省略字段（对齐安卓 Gson null 省略）
            if partySeatIndex > 0 {
                expand["seatIndex"] = partySeatIndex
            }
        }
        let payload: [String: Any] = [
            "requestId": DeviceInfo.deviceId,
            "messageType": 1,
            "expandParams": expand,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        guard let task else { return }
        task.send(.string(str)) { [weak self] err in
            if let err {
                AppLogger.heartbeat.notice("⚠️ [WS] send 失败 status=\(status.rawValue, privacy: .public) err=\(err.localizedDescription, privacy: .private)")
                Task { @MainActor in self?.scheduleReconnect() }
            }
        }
    }

    // MARK: - 派对房上下文（安卓确认 + spec v3）
    //
    // 实现简化：不启独立 timer，仅更新字段 + 立即补一发 sendStatus，
    // 让现有 15s pingTask 自然承载（与安卓主播端单心跳模型一致）。

    /// 派对房进退房 / 上下麦时调用。`roomId` 空 → 清空。
    /// `seatIndex` >0 表示具体麦位号 1-13；其余视为不在麦上（不带该字段）。
    func setPartyContext(roomId: String, seatIndex: Int) {
        partyRoomId = roomId
        partySeatIndex = seatIndex
        AppLogger.heartbeat.notice("📡 [WS] partyContext roomId=\(roomId, privacy: .public) seatIdx=\(seatIndex, privacy: .public)")
        // 立即补一发让服务端尽快感知新上下文
        sendStatus(currentStatus)
    }

    func clearPartyContext() {
        partyRoomId = ""
        partySeatIndex = -1
        AppLogger.heartbeat.notice("📡 [WS] partyContext cleared")
        sendStatus(currentStatus)
    }

    // MARK: - 计时器

    private func startPing() {
        cancelPing()
        pingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, !self.disposed {
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
                if Task.isCancelled || self.disposed { break }
                // 读 currentStatus：通话期保持 .calling，空闲期保持 .callEnd，对齐 H5 getOnlineStatus
                self.sendStatus(self.currentStatus)
            }
        }
    }

    private func scheduleReconnect() {
        guard !disposed else { return }
        cancelReconnect()
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        cancelPing()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.reconnectDelay ?? 5) * 1_000_000_000))
            if Task.isCancelled { return }
            self?.connect()
        }
    }

    private func cancelPing()      { pingTask?.cancel();      pingTask = nil }
    private func cancelReconnect() { reconnectTask?.cancel(); reconnectTask = nil }

    // MARK: - 前后台

    // 对齐 H5 useUserHeartbeatState.lineStateSetter：进后台先 clearSendTimer 再补一条 BACKGROUND；
    // 回前台 resetSend 重启周期。iOS 之前漏了 cancelPing，pingTask 在后台 5s 一次又把状态拉回
    // .callEnd，把"主播在后台"伪装成"主播在线可拨"。
    @objc private func onForeground() {
        guard !disposed else { return }
        if task == nil {
            connect()  // connect() 内会 startPing
        } else {
            sendStatus(currentStatus)  // 通话期 currentStatus=.calling，空闲期=.callEnd
            startPing()  // 后台时已 cancelPing，回前台必须重启
        }
    }

    @objc private func onBackground() {
        guard !disposed else { return }
        cancelPing()
        sendStatus(.background)  // 后台一次性补 BACKGROUND，不修改 currentStatus
    }

    // MARK: - D 联动入口（LiveStore.pauseForCall / resumeCall 调用）

    /// 通话状态切换通知。callState=1 时切 .calling 立即上报；callState=0 时切回 .callEnd。
    /// 对齐 H5 `getOnlineStatus`：`checkOnCall ? CALLING : CALL_END`。
    /// waitingReturnLive 期间应继续保持 .calling（LiveStore.resumeCall 内倒计时结束才调本方法切回）。
    func notifyCallStateChanged(callState: Int) {
        let next: OnlineStatus = (callState == 1) ? .calling : .callEnd
        guard currentStatus != next else { return }
        currentStatus = next
        sendStatus(next)
        AppLogger.heartbeat.debug("📡 [WS] notifyCallStateChanged callState=\(callState, privacy: .public) → onlineStatus=\(next.rawValue, privacy: .public)")
    }

    // MARK: - Work 悬浮开关联动（OnlineStatusStore.setUserSetOnline 调用）

    /// 用户手动切换在线态时立即通过 WS 上报，不等下一次 15s ping tick。
    /// 对齐已有 `notifyCallStateChanged` 模式：变更 currentStatus + 立即 sendStatus。
    ///
    /// **优先级**：用户显式意图 → 无条件覆盖 currentStatus。
    /// - 通话中用户点下线：`.offline` 覆盖 `.calling`（业务上应禁止通话中下线，UI 未做保护）
    /// - 从下线态恢复上线：置回 `.callEnd`（若期间正好在通话，LiveStore.resumeCall 会通过
    ///   `notifyCallStateChanged` 再切回 `.calling` 覆盖）
    func reportManualOnlineStatus(isOnline: Bool) {
        let next: OnlineStatus = isOnline ? .callEnd : .offline
        guard currentStatus != next else { return }
        currentStatus = next
        sendStatus(next)
        AppLogger.heartbeat.debug("📡 [WS] reportManualOnlineStatus isOnline=\(isOnline, privacy: .public) → onlineStatus=\(next.rawValue, privacy: .public)")
    }
}
