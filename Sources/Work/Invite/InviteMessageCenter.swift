import Foundation
import SwiftUI

/// attachType 103/104 的全局裂变消息。router 只观察、不消费，保证原有聊天系统提示继续入会话。
@MainActor
final class InviteMessageCenter: ObservableObject {
    static let shared = InviteMessageCenter()

    @Published private(set) var current: InviteChatPrompt?
    @Published private(set) var isAtRootPage = true
    private var queue: [InviteChatPrompt] = []
    private var lastShownID: UUID?

    private init() {}

    func enqueue(_ prompt: InviteChatPrompt) {
        guard !prompt.yxAccid.isEmpty else { return }
        // H5 只对 104 做同一用户去重；103 代表新的充值事件，不能吞掉后续通知。
        if prompt.attachType == 104 {
            guard current?.yxAccid != prompt.yxAccid,
                  !queue.contains(where: { $0.yxAccid == prompt.yxAccid }) else { return }
        }
        if current == nil {
            current = prompt
        } else {
            queue.append(prompt)
        }
    }

    func updateDisplayContext(isAtRootPage: Bool) {
        self.isAtRootPage = isAtRootPage
    }

    /// 消息队列属于当前登录会话，登出后不能带入下一账号。
    func clear() {
        current = nil
        queue.removeAll()
        lastShownID = nil
        isAtRootPage = false
    }

    func markShown(_ prompt: InviteChatPrompt) {
        guard current?.id == prompt.id, lastShownID != prompt.id else { return }
        lastShownID = prompt.id
        AnalyticsTracker.track("invite_hostPush_card_show", properties: [
            "type": prompt.attachType == 103 ? "successRecharge" : "noRecharge",
            "userId": prompt.userID,
        ])
    }

    func dismissCurrent(expectedID: UUID? = nil) {
        guard expectedID == nil || current?.id == expectedID else { return }
        current = queue.isEmpty ? nil : queue.removeFirst()
    }

    func startChat() {
        guard let current else { return }
        AnalyticsTracker.track("invite_hostPush_card_click", properties: [
            "type": current.attachType == 103 ? "successRecharge" : "noRecharge",
            "userId": current.userID,
        ])
        NotificationCenter.default.post(name: .inviteChatRequested, object: nil, userInfo: ["yxAccid": current.yxAccid])
        dismissCurrent()
    }
}

struct InviteChatPrompt: Identifiable, Equatable {
    let id = UUID()
    let attachType: Int
    let userID: String
    let yxAccid: String
    let nickname: String
    let iconURL: String?
    let content: String

    init?(attachType: Int, payload: [String: Any]) {
        let nested = payload["data"] as? [String: Any]
        userID = InviteChatPrompt.string(payload["userId"])
            ?? InviteChatPrompt.string(nested?["userId"])
            ?? ""
        yxAccid = InviteChatPrompt.string(payload["userYxAccid"])
            ?? InviteChatPrompt.string(payload["yxAccid"])
            ?? InviteChatPrompt.string(nested?["userYxAccid"])
            ?? InviteChatPrompt.string(nested?["yxAccid"])
            ?? ""
        guard !yxAccid.isEmpty else { return nil }
        self.attachType = attachType
        nickname = InviteChatPrompt.string(payload["nickname"])
            ?? InviteChatPrompt.string(payload["nickName"])
            ?? InviteChatPrompt.string(nested?["nickname"])
            ?? L10n.anonymous
        iconURL = InviteChatPrompt.string(payload["icon"])
            ?? InviteChatPrompt.string(payload["avatar"])
            ?? InviteChatPrompt.string(nested?["icon"])
        content = InviteChatPrompt.string(payload["content"])
            ?? InviteChatPrompt.string(nested?["content"])
            ?? ""
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }
}

@MainActor
final class InviteMessageRouter: MessageRouter {
    static let shared = InviteMessageRouter()
    private init() {}

    func route(_ attachType: AttachType, payload: [String: Any], context: MessageContext) -> Bool {
        observe(attachType, payload: payload, context: context)
        return false
    }
}

extension InviteMessageRouter {
    /// Swift 的 enum case pattern 不能直接在 guard 中同时匹配两个 context，保持路由为观察者。
    func observe(_ attachType: AttachType, payload: [String: Any], context: MessageContext) {
        switch context {
        case .sysMsg, .syncSysMsg: break
        default: return
        }
        let rawType: Int
        switch attachType {
        case .userBindAfterRecharged: rawType = 103
        case .userBindAfterNotRecharged: rawType = 104
        default: return
        }
        // RootView 仅在 active 状态展示；这里仍要收下后台/子页期间到达的消息，
        // 否则用户回到根页时会永久丢失该条邀请引导。
        guard let prompt = InviteChatPrompt(attachType: rawType, payload: payload) else { return }
        InviteMessageCenter.shared.enqueue(prompt)
    }
}

/// RootView 挂载的邀请消息卡片，对齐 H5：10s 自动消失、上滑忽略、FIFO 消费。
struct InviteMessageCard: View {
    @ObservedObject var center: InviteMessageCenter
    let prompt: InviteChatPrompt

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(urlString: prompt.iconURL, size: 46, kind: .user, userId: prompt.userID, disablesTap: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(prompt.nickname)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !prompt.content.isEmpty {
                    Text(prompt.content)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Button(L10n.Invite.startChat) { center.startChat() }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color(hex: 0x9D2BE3))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color(hex: 0x32104D).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 12, y: 5)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .task(id: prompt.id) {
            center.markShown(prompt)
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                center.dismissCurrent(expectedID: prompt.id)
            } catch is CancellationError {
                // 卡片替换/页面销毁主动取消，预期路径。
            } catch {
                AppLogger.net.notice("[Invite] card countdown failed: \(String(describing: error), privacy: .private)")
            }
        }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height < -50 { center.dismissCurrent() }
                }
        )
    }
}

extension Notification.Name {
    static let inviteChatRequested = Notification.Name("inviteChatRequested")
}
