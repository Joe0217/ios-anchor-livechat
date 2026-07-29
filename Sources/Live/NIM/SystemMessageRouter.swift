import Foundation
import UIKit
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "sys-msg-router")

/// 系统消息路由（H 里程碑 spec §3.1）。
///
/// 负责 `nim.on('sysMsg', ...)` 收到的所有 `attachType` 分发到对应业务 store。
///
/// **M4 范围**：H 核心 12 case（spec §6.2 渐进式接入）：
/// - 强制下播 / 合规：44 forceEndLive / 61 complianceWarning / 62 banned / 63 boostingExposure / 64 boostingExposureExit
/// - 通话相关：-3 callCancel 辅助信令 / -6 callPayWaitState / -1 callRemoteMessage / 15 callIncomePerMinute / 18 callGiftIncome / 90 callRechargeReward
/// - SessionStore：-4 followIncrement / 58 anchorAuditChange
///
/// **未覆盖 case**（spec §6.2 R2 缓解）：进入 default 分支仅 `logger.debug` 不噪音不阻塞业务，
/// 后续 I/J 期按需扩展只动 switch case 不破协议。
///
/// **通道范围**（spec §1.1.2）：
/// 本 router 只在 `.sysMsg` / `.syncSysMsg` 通道分发；`.liveChatroom` / `.partyChatroom` / `.p2p`
/// 直接 `return false` 让链路下游或回到 chatroom 主路径处理。
/// 44/61/62/63/64 在 B 期 iOS 路径**只有**心跳 1992/1006（HeartbeatController）触发 forceEnd，
/// H M4 sysMsg 路径是首次补齐 H5 已有的 sysMsg 触发入口（不重复触发；不与 chatroom 路径冲突）。
/// LiveStore.forceEnd 内部 `inFlightEnd` 守卫天然兼容多源并发触发。
///
/// **单例设计**（H M4 收尾）：sysMsg 全局只有一条流，多实例 router 并存会导致先注册者
/// `liveStore=nil` 时 case `.forceEndLive` 仍 `return true` 短路掉后注册者真实路径。
/// 改为 shared 单例后由 `NIMService.setupOnce` 一次性注入 `callStore` / `sessionStore`，
/// `liveStore` 在 `LiveRoomView.onAppear` 注入、`onDisappear` 清空（weak 兜底）。
@MainActor
final class SystemMessageRouter: MessageRouter {

    static let shared = SystemMessageRouter()

    weak var liveStore: LiveStore?
    weak var callStore: CallStore?
    weak var sessionStore: SessionStore?
    weak var robotCallStore: RobotCallStore?

    /// 回前台 5s 冷却结束时间。NIM SDK 重连完成 `loginOK` 后会**逐条补发**离线 backlog
    /// （NIMService.swift:288-298 注释自承），此时 applicationState 已是 .active，单 background
    /// guard 拦不住 → 回前台瞬间触发 forceEnd。对齐 NetworkQualityMonitor 的同款冷却策略。
    private var foregroundCooldownUntil: Date?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleWillEnterForeground() {
        foregroundCooldownUntil = Date().addingTimeInterval(5)
        logger.info("[SysMsgRouter] will enter foreground; 5s cooldown to drop NIM SDK backlog")
    }

    func route(_ attachType: AttachType,
               payload: [String: Any],
               context: MessageContext) -> Bool {
        let action = SystemMessageRouteDecision.decide(
            attachType: attachType, payload: payload, context: context
        )
        return execute(action, attachType: attachType, context: context)
    }

    /// 把 `SystemMessageAction` 派发到对应 store；动作 ≠ `.passThrough` 时即认为消费链路。
    private func execute(_ action: SystemMessageAction,
                         attachType: AttachType,
                         context: MessageContext) -> Bool {
        switch action {
        case .forceEndLive(let sub):
            // 后台守卫 + 回前台 5s 冷却：sysMsg 推送下播独立于 HeartbeatController，必须自带防御。
            // 对齐 HeartbeatController.tick:46-50 + NetworkQualityMonitor cooldown 模式。
            guard UIApplication.shared.applicationState != .background else {
                logger.info("[SysMsgRouter] forceEndLive deferred: app in background sub=\(sub, privacy: .public)")
                return true
            }
            if let cd = foregroundCooldownUntil, Date() < cd {
                logger.info("[SysMsgRouter] forceEndLive deferred: foreground cooldown sub=\(sub, privacy: .public)")
                return true
            }
            Task { @MainActor [weak self] in
                await self?.liveStore?.forceEnd(reason: .disconnected, subSource: sub)
            }
        case .banned(let sub):
            guard UIApplication.shared.applicationState != .background else {
                logger.info("[SysMsgRouter] banned deferred: app in background sub=\(sub, privacy: .public)")
                return true
            }
            if let cd = foregroundCooldownUntil, Date() < cd {
                logger.info("[SysMsgRouter] banned deferred: foreground cooldown sub=\(sub, privacy: .public)")
                return true
            }
            Task { @MainActor [weak self] in
                await self?.liveStore?.forceEnd(reason: .banned, subSource: sub)
            }
        case .complianceWarning(let text):
            // payload 缺 content 时 decide 返空串；这里兜底为 L10n 默认文案
            liveStore?.warn(message: text.isEmpty ? L10n.complianceWarningDefault : text)
        case .markBoostingExposure(let on):
            liveStore?.markBoostingExposure(on)
        case .callRemoteText(let text, let chatBubble, let sender):
            callStore?.handleRemoteText(text, chatBubble: chatBubble, sender: sender)
        case .callWaitState(let type):
            callStore?.updateWaitState(type: type)
        case .callIncome(let delta):
            callStore?.appendCallIncome(num: delta)
        case .callGiftIncome(let delta):
            callStore?.appendGiftIncome(num: delta)
        case .callRechargeReward(let delta):
            callStore?.appendWaitBonus(num: delta)
        case .callNimSignal(let type, let channelId, let sender):
            callStore?.handleNimCallSignal(type: type, channelId: channelId, sender: sender)
        case .robotCallIncoming(let invite):
            guard let invite else {
                logger.warning("[SysMsgRouter] robot call incoming missing required payload")
                break
            }
            robotCallStore?.receiveIncoming(invite)
        case .robotCallReward(let reward):
            guard let reward else {
                logger.warning("[SysMsgRouter] robot call reward missing recordId")
                break
            }
            robotCallStore?.receiveReward(reward)
        case .followIncrement:
            sessionStore?.incrementFollow()
        case .anchorAuditChange(let s, let c):
            sessionStore?.handleAuditStatus(applyStatus: s, content: c)
        case .checkForcedBusy:
            // 对齐安卓 HomeHomeFragment queryHideState(false, true)：静默查超限 + 弹窗
            // 走 triggerCheckForcedBusy 统一到 activeCheckTask 串行化（审查报告-202607061550 必修-2）
            OnlineStatusStore.shared.triggerCheckForcedBusy(showToast: false, doAction: true)
        case .privateCallSwitchChange(let open):
            liveStore?.setPrivateCallOpen(open)
            logger.info("[SysMsgRouter] privateCallSwitchChange → LiveStore.privateCallOpen=\(open, privacy: .public)")
        case .passThrough:
            logger.debug("[SysMsgRouter] passThrough \(attachType.raw, privacy: .public) ctx=\(String(describing: context), privacy: .public)")
        }
        return action != .passThrough
    }
}
