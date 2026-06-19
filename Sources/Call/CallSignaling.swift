import Foundation
import AgoraRtmKit

/// RTM 信令收发回调（由 CallStore 实现）
@MainActor
protocol CallSignalingDelegate: AnyObject {
    /// 收到对端 CallMessage；publisher 是发送方 userId（字符串）
    func signaling(_ signaling: CallSignaling, didReceive message: CallMessage, from publisher: String)
    /// 致命登录冲突（同 UID 在别处登录 / 被服务端封禁）
    func signalingDidDetectSameUidLogin(_ signaling: CallSignaling)
}

/// 1v1 通话 RTM 信令通道。
///
/// 与 H5 `callApi/messageManager/rtm.ts` + `useCallApi.js` 对端互通：
/// - 每条消息 = `CallMessage` JSON UTF-8 字符串
/// - 发往对端用 `channelType = .user`，channelName 填对端 userId
/// - 自身只需 login，RTM 2.x 在 user 通道发的消息会自动送达对端的 didReceiveMessageEvent
///
/// 重连 / token 续期 / 致命态 全部委托 RtmReconnect。
@MainActor
final class CallSignaling: NSObject {
    weak var delegate: CallSignalingDelegate?

    /// 本端 userId（数字，与 H5 CallMessage.fromUserId 类型一致）
    let myUserId: Int

    private let reconnect = RtmReconnect()
    private var client: AgoraRtmClientKit?

    init(myUserId: Int) {
        self.myUserId = myUserId
        super.init()
    }

    var isLoggedIn: Bool { client != nil }

    // MARK: - 登录 / 登出

    /// 用 getAgoraRtmToken 拿到的 rtmToken 登录，并绑定重连大脑。
    /// refreshToken 回调由调用方提供（H5 等价：myCallStore.handleGetAgoraRtmToken）
    /// ⚠️ 失败路径必须显式 logout + 置 nil，否则 AgoraRtmClientKit 内部线程 / socket 泄漏。
    func login(token: String,
               refreshToken: @escaping () async -> String?) async throws {
        if client != nil { return }
        let config = AgoraRtmClientConfig(appId: AgoraConfig.appId, userId: String(myUserId))
        let kit = try AgoraRtmClientKit(config, delegate: self)
        client = kit

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                kit.login(token) { _, err in
                    if let err {
                        cont.resume(throwing: APIError(
                            code: "\(err.errorCode.rawValue)",
                            message: err.reason.isEmpty ? "RTM 登录失败" : err.reason))
                    } else {
                        cont.resume()
                    }
                }
            }
        } catch {
            // 释放半生 client 防止线程/事件回调泄漏。logout 只断连，destroy 才释放 SDK 资源。
            kit.logout(nil)
            _ = kit.destroy()
            client = nil
            throw error
        }

        reconnect.bind(
            client: kit,
            refreshToken: refreshToken,
            onSameUidLogin: { [weak self] in
                guard let self else { return }
                self.delegate?.signalingDidDetectSameUidLogin(self)
            }
        )
        print("📶 [Signaling] login 成功 uid=\(myUserId)")
    }

    func logout() {
        if let client = client {
            // ⚠️ logout 只断网络连接，**必须再调 destroy** 才能释放 SDK 进程级资源
            //（线程/socket/事件回调表）。少了 destroy 第二次 init 新 client 时与旧实例的
            // 内部状态冲突，表现为重登后 publish 不出去、收不到对端信令。
            client.logout(nil)
            let code = client.destroy()
            print("📶 [Signaling] logout + destroy code=\(code.rawValue)")
        }
        reconnect.dispose()
        client = nil
    }

    // MARK: - 发消息

    /// 向对端发一条已构造好的 CallMessage。
    ///
    /// ⚠️ 必须用 `publish(channelName:data:option:)`（二进制）而非 `message:`（字符串）：
    /// H5 callApi/messageManager/rtm.ts:27 用 `encodeUint8Array(jsonString)` 发的是 Uint8Array，
    /// 对端用 `decodeUint8Array(message as Uint8Array)` 解；若我们发 NSString，H5 SDK 内部
    /// `TextDecoder.decode(ArrayBuffer)` 会报"parameter 1 is not of type 'ArrayBuffer'"。
    @discardableResult
    func publish(_ message: CallMessage) async -> Bool {
        guard let client else {
            print("⚠️ [Signaling] publish 跳过：client 未就绪 action=\(message.messageAction)")
            return false
        }
        guard let data = try? JSONEncoder().encode(message) else {
            print("⚠️ [Signaling] encode CallMessage 失败 action=\(message.messageAction)")
            return false
        }
        let toUserId = String(message.remoteUserId)
        let opts = AgoraRtmPublishOptions()
        opts.channelType = .user

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            client.publish(channelName: toUserId, data: data, option: opts) { [weak self] _, err in
                Task { @MainActor in
                    guard let self else { cont.resume(returning: false); return }
                    if let err {
                        print("⚠️ [Signaling] publish 失败 action=\(message.messageAction) to=\(toUserId) code=\(err.errorCode.rawValue) msg=\(err.reason)")
                        self.reconnect.triggerReconnect(reason: "publish_failed_\(err.errorCode.rawValue)")
                        cont.resume(returning: false)
                    } else {
                        print("📤 [Signaling] publish 成功 action=\(message.messageAction) to=\(toUserId) ch=\(message.fromRoomId ?? "-") callId=\(message.callId) bytes=\(data.count)")
                        cont.resume(returning: true)
                    }
                }
            }
        }
    }
}

// MARK: - AgoraRtmClientDelegate

// OC 回调线程不在 MainActor，需要 nonisolated 桥接后 hop 回 MainActor。
extension CallSignaling: AgoraRtmClientDelegate {
    nonisolated func rtmKit(_ rtmKit: AgoraRtmClientKit,
                            didReceiveMessageEvent event: AgoraRtmMessageEvent) {
        // 只关心 P2P user 通道；其余（stream/message）暂不接入
        guard event.channelType == .user else { return }
        // 对端（H5/安卓）都按二进制 Uint8Array 发送，优先读 rawData；stringData 仅作兜底。
        let payload: Data?
        if let raw = event.message.rawData, !raw.isEmpty {
            payload = raw
        } else if let s = event.message.stringData, let d = s.data(using: .utf8) {
            payload = d
        } else {
            payload = nil
        }
        guard let data = payload,
              let msg = try? JSONDecoder().decode(CallMessage.self, from: data) else {
            let preview = payload.flatMap { String(data: $0.prefix(120), encoding: .utf8) } ?? "<nil>"
            print("⚠️ [Signaling] 无法解析 RTM 消息 from=\(event.publisher) ch=\(event.channelName) preview=\(preview)")
            return
        }
        let publisher = event.publisher
        Task { @MainActor [weak self] in
            guard let self else { return }
            print("📥 [Signaling] 收到 action=\(msg.messageAction) from=\(publisher) callId=\(msg.callId) fromRoomId=\(msg.fromRoomId ?? "-")")
            self.delegate?.signaling(self, didReceive: msg, from: publisher)
        }
    }

    nonisolated func rtmKit(_ rtmKit: AgoraRtmClientKit,
                            channel channelName: String,
                            connectionChangedToState state: AgoraRtmClientConnectionState,
                            reason: AgoraRtmClientConnectionChangeReason) {
        print("📶 [Signaling] connection state=\(state.rawValue) reason=\(reason.rawValue) channel=\(channelName)")
        Task { @MainActor [weak self] in
            self?.reconnect.handleConnectionChange(state: state, reason: reason)
        }
    }

    nonisolated func rtmKit(_ rtmKit: AgoraRtmClientKit,
                            tokenPrivilegeWillExpire channel: String?) {
        print("📶 [Signaling] tokenPrivilegeWillExpire channel=\(channel ?? "nil")")
        Task { @MainActor [weak self] in
            self?.reconnect.handleTokenPrivilegeWillExpire()
        }
    }
}
