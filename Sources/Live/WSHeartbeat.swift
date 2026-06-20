import Foundation
import UIKit

/// 主播在线态 WebSocket 心跳（对应 H5 `useUserHeartbeatState.js`）。
///
/// **这是用户端"看到主播在线"的唯一来源**——后端按 WS 长连接 + 5s 心跳里的 `onlineStatus`
/// 维护 `onlineGroupStatus`。NIM 长连虽然必要（用于 IM 消息），但 dev 环境的"主播是否在线"
/// 列表字段由本通道驱动。
///
/// 协议（与 H5 严格对齐）：
/// - 握手 URL：`{socketBaseURL}/webSocket?ciphertext={AES_Base64({"appToken":<loginUuid>})}`
/// - 心跳间隔 5 秒
/// - 心跳 payload：`{"requestId":"<deviceId>","messageType":1,"expandParams":{"channelId":"","onlineStatus":<int>}}`
/// - onlineStatus 取值：见 LIVE_STATUS_NUMBER（H5 `src/constant/live.ts`）
///     1=ONLINE / 2=OFFLINE / 3=DISCONNECT / 10000=CALLING / 10001=CALL_END
///     10002=FOREGROUND / 10003=BACKGROUND
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
    private let interval: TimeInterval = 5
    private let reconnectDelay: TimeInterval = 5

    /// 当前应发的"在线态"状态。startPing/前后台切换/重连握手首包统一读取此值，
    /// 由 `notifyCallStateChanged(callState:)` 改写，让通话状态变化能影响周期心跳值。
    /// 默认 `.callEnd`（空闲在线）。
    private var currentStatus: OnlineStatus = .callEnd

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
            print("⚠️ [WS] 握手 URL 构造失败")
            return
        }
        let queryLen = (url.query?.count ?? 0)
        print("📡 [WS] connecting host=\(url.host ?? "?") path=\(url.path) queryLen=\(queryLen)")
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        startReceiveLoop()
        // ⚠️ 首包发 currentStatus 不发 .foreground：H5 getOnlineStatus 空闲态返回 CALL_END(10001)，
        // 后端按此判定"可拨打"。FOREGROUND(10002) 是"刚回到前台"的瞬时状态，长期上报后端会
        // 拒绝 createCall（1111 "current status unable to make a call"）。
        // 通话期重连握手时 currentStatus 已是 .calling，确保 D 联动不中断。
        sendStatus(currentStatus)
        startPing()
        connected = true
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
        print("📡 [WS] cipher(hex) len=\(cipher.count) head=\(cipher.prefix(12))…")
        return URL(string: "\(AppConfig.socketBaseURL)/webSocket?ciphertext=\(cipher)")
    }

    // MARK: - URLSessionWebSocketDelegate（拿 HTTP 响应诊断握手）

    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol p: String?) {
        print("📡 [WS] didOpen protocol=\(p ?? "nil")")
    }

    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "<nil>"
        print("📡 [WS] didClose code=\(closeCode.rawValue) reason=\(reasonStr)")
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        let resp = task.response as? HTTPURLResponse
        let body = (task as? URLSessionDataTask).flatMap { _ in "" } ?? ""
        print("📡 [WS] task didComplete status=\(resp?.statusCode ?? -1) err=\(error?.localizedDescription ?? "nil") body=\(body)")
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
                    print("📡 [WS] receive 失败: \(err.localizedDescription) → 调度重连")
                    self.connected = false
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func sendStatus(_ status: OnlineStatus, channelId: String = "") {
        let payload: [String: Any] = [
            "requestId": DeviceInfo.deviceId,
            "messageType": 1,
            "expandParams": [
                "channelId": channelId,
                "onlineStatus": status.rawValue,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        guard let task else { return }
        task.send(.string(str)) { [weak self] err in
            if let err {
                print("⚠️ [WS] send 失败 status=\(status.rawValue) err=\(err.localizedDescription)")
                Task { @MainActor in self?.scheduleReconnect() }
            }
        }
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
        print("📡 [WS] notifyCallStateChanged callState=\(callState) → onlineStatus=\(next.rawValue)")
    }
}
