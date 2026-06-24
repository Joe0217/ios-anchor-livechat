import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "PKNIMRouter")

/// G 里程碑 spec §5 / M4-1：把云信 PK 自定义消息解码并路由到 `PKStore`。
///
/// 分发表（spec §5.2 + H5 live.js:548-648 校验）：
/// - attachType=97 → `PKInviteInfo` → `handle97_invite`
/// - attachType=98 → `PKScoreUpdate` → `handle98_score`
/// - attachType=99 → `PKInviteAck` → `handle99_ack`
/// - attachType=100 → `PKStatusBundle` → `handle100_status`（内部按 pkStatus 7/8/9/10/-1 子分发）
/// - attachType=-8 → 静音对方广播；主态收到通常是自己刚发的回响，忽略；客户态用于同步 mute UI（G 范围外）
/// - attachType=-9 → PK 公屏通知（开始/胜负/Top3）；公屏文本由 NIMChatroomManager 主路径展示，本路由不直接干预
///
/// **未就绪兜底**：PKStore 为 nil 时（LiveRoomView 尚未注入或已 teardown）日志告警 + 丢弃，不抛错。
/// **过期消息丢弃**：PKStore 状态与消息类型不匹配时由 PKStore 内部 guard 各 handle* 自行拒绝。
@MainActor
final class PKNIMRouter {
    weak var pkStore: PKStore?

    init(pkStore: PKStore? = nil) {
        self.pkStore = pkStore
    }

    /// 路由入口：上游传入的 `payload` 是 NIM remoteExt 顶层字典。
    /// **H5 蓝本 live.js:552 `const { attachType, data } = ext`**——业务字段嵌套在 `data` 层：
    /// - 97/98/99/100 → 业务字典在 `payload["data"]`
    /// - -8/-9 → 字段直接在顶层 payload（H5 live.js:326/334 取 `ext.muteOppositeAnchor` / `ext.content`）
    func route(_ at: AttachType, payload: [String: Any]) {
        guard let store = pkStore else {
            logger.warning("PKNIMRouter: pkStore nil, drop \(at.raw, privacy: .public)")
            return
        }
        // 97/98/99/100 业务字段在 data 嵌套层；缺失 data 时用顶层兜底（部分老接口可能也允许扁平）
        let businessDict: [String: Any] = (payload["data"] as? [String: Any]) ?? payload
        switch at {
        case .pkInvite:
            if let info: PKInviteInfo = decode(from: businessDict) {
                store.handle97_invite(info)
            }
        case .pkScoreUpdate:
            if let update: PKScoreUpdate = decode(from: businessDict) {
                store.handle98_score(update)
            }
        case .pkInviteAck:
            if let ack: PKInviteAck = decode(from: businessDict) {
                store.handle99_ack(ack)
            }
        case .pkStatusBundle:
            if let bundle: PKStatusBundle = decode(from: businessDict) {
                store.handle100_status(bundle)
            }
        case .pkMuteBroadcast:
            // 自己发的静音命令的回响 / 观众端用；主态忽略
            logger.info("PKNIMRouter: pkMuteBroadcast received (no-op for host)")
        case .pkChatNotice:
            // 公屏富文本由 NIMChatroomManager 主路径展示，PKNIMRouter 不重复处理
            logger.info("PKNIMRouter: pkChatNotice handled by chat path")
        default:
            // 非 PK 段进入本路由属于上游过滤失败，仅 logger 告警
            logger.warning("PKNIMRouter: non-PK attachType \(at.raw, privacy: .public) ignored")
        }
    }

    // MARK: - decode helper

    private func decode<T: Decodable>(from dict: [String: Any]) -> T? {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict) else {
            logger.warning("PKNIMRouter: payload not JSON-valid for \(T.self, privacy: .public)")
            return nil
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            logger.warning("PKNIMRouter: decode \(T.self, privacy: .public) failed: \(String(describing: error), privacy: .private)")
            return nil
        }
    }
}

// MARK: - MessageRouter 适配（H M2）

/// H M2-1：PKNIMRouter 实现 `MessageRouter` protocol，让 NIMService.dispatch 链路能路由到 PK。
///
/// **双轨过渡**（M2 → M5）：
/// - M2：本 extension 让 PKNIMRouter 符合 protocol；同时旧路径（NIMChatroomManager.onRecvMessages
///   直接调 `pkRouter.route(_:payload:)`）保留——M2 阶段 NIMService.dispatch **不会**触发本 router（PK 消息走 chatroomMsg
///   不走 sysMsg，且 NIMChatroomManager 还未改走 NIMService 分发）。
/// - M5：NIMChatroomManager.onRecvMessages 改成 `NIMService.shared.dispatch(_:payload:context:.liveChatroom)`，
///   届时本 extension 实际生效；旧路径 + `weak pkRouter` 字段一并删除。
///
/// 旧 `route(_ at:payload:)` 保留为 internal helper，避免 G 既有调用点破坏。
extension PKNIMRouter: MessageRouter {

    func route(_ attachType: AttachType,
               payload: [String: Any],
               context: MessageContext) -> Bool {
        // PK 消息只走 liveChatroom 通道
        guard case .liveChatroom = context else { return false }
        switch attachType {
        case .pkInvite, .pkScoreUpdate, .pkInviteAck, .pkStatusBundle,
             .pkMuteBroadcast, .pkChatNotice:
            self.route(attachType, payload: payload)
            return true
        default:
            return false
        }
    }
}
