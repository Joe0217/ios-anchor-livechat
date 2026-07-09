import SwiftUI

/// P2P 会话单行（v3 UI 对齐 H5）：头像 + 昵称 + 时间 + 消息预览 + 未读 badge。
///
/// **无业务态**：session + 长按回调由父注入。父视图承载 confirmation dialog bottom sheet（Unpin/Delete）。
///
/// **无障碍**：行整体 combine，标签含未读数。
struct MessageSessionRow: View {

    let session: MessageSession
    /// v4e：对端画像（等级/VIP/活跃大 R）；view 层从 store.profile(for:) 传入，缺则不显示对应 badge
    let profile: ConversationProfile?
    let onLongPress: () -> Void
    /// H-2 spec §4.1：短按 push chat detail；nil 时不响应（如系统入口 row 复用）
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            avatar
            mainInfo
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        // longPress 优先注册，避免 tap 抢占；SwiftUI 的 .onTapGesture + .onLongPressGesture
        // 一起用需要 longPress 靠前 SwiftUI 才能同时识别
        .onLongPressGesture(minimumDuration: 0.4, perform: onLongPress)
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    // MARK: - Components

    private var avatar: some View {
        // v4e：在线状态 dot 三态（对齐 H5 CAvatar 语义）与 AvatarView 内置绿点语义不同（三态：在线/离线/隐藏），
        // 因此不使用 showsOnlineDot，走外层 overlay 定制。
        AvatarView(urlString: session.peerAvatarURL, size: 48, kind: .user)
            .overlay(alignment: .bottomTrailing) {
                if let p = profile, p.hasOnlineStatus {
                    Circle()
                        .fill(p.isOnlineForCall ? Color.green : Color.gray)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                        .accessibilityLabel(p.isOnlineForCall ? L10n.messageA11yOnline : L10n.messageA11yOffline)
                }
            }
            .accessibilityHidden(profile?.hasOnlineStatus != true)
    }

    private var mainInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 昵称行：pin 图标 + nickname + 活跃大 R + 等级 + VIP（对齐 H5 list.vue:354-373）
            HStack(spacing: 4) {
                if session.isTop {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                Text(session.peerNickname)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if profile?.activeTycoon == true {
                    ActiveTycoonBadge()
                }
                if let name = profile?.userLevelName, profile?.showsLevelBadge == true {
                    UserLevelBadge(levelName: name)
                }
                if profile?.isVIPActive() == true {
                    VIPBadge()
                }
            }
            Text(session.lastMessage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var trailing: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(MessageTimeFormatter.formatTalkTime(session.lastMessageTimestamp))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if session.unreadCount > 0 {
                Text(session.unreadCount > 99 ? "99+" : "\(session.unreadCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red, in: Capsule())
                    .accessibilityHidden(true)
            }
        }
    }

    private var a11yLabel: String {
        var parts = [session.peerNickname, session.lastMessage]
        if session.unreadCount > 0 { parts.append(L10n.messageA11yUnreadCountFormat(session.unreadCount)) }
        if session.isTop { parts.append(L10n.messageA11yPinned) }
        return parts.joined(separator: ", ")
    }
}

/// H5 formatTalkTime 语义对齐（v3 §1.4b #6）。
///
/// - 今天：HH:mm
/// - 昨天：Yesterday
/// - 本周（7 天内）：EEE（Mon/Tue/...）
/// - 更早：MM-dd
enum MessageTimeFormatter {

    static func formatTalkTime(_ millis: Int64, now: Date = Date()) -> String {
        guard millis > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        let cal = Calendar(identifier: .gregorian)

        if cal.isDate(date, inSameDayAs: now) {
            return formatted(date, "HH:mm")
        }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now),
           cal.isDate(date, inSameDayAs: yesterday) {
            return L10n.messageTimeYesterday
        }
        if let sevenDaysAgo = cal.date(byAdding: .day, value: -7, to: now),
           date > sevenDaysAgo {
            return formatted(date, "EEE")
        }
        return formatted(date, "MM-dd")
    }

    /// v5 F-5: DateFormatter 显式 locale = Locale.current；否则 EEE/MM-dd 跟随
    /// preferredLanguages 与 app 语言分裂（阿语界面显示英语周几名）。
    private static func formatted(_ date: Date, _ format: String) -> String {
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = format
        return df.string(from: date)
    }
}

#if DEBUG
struct MessageSessionRow_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 0) {
            MessageSessionRow(
                session: .init(id: "u1", peerNickname: "Alice", peerAvatarURL: nil,
                               lastMessage: "Hi there!", lastMessageTimestamp: Int64(Date().timeIntervalSince1970 * 1000),
                               unreadCount: 3, isTop: true, ext: .empty),
                profile: ConversationProfile(nickname: "Alice", icon: nil, userLevelName: "35",
                                             vipExpireTime: Int64((Date().timeIntervalSince1970 + 86400) * 1000),
                                             activeTycoon: true, onlineGroupStatus: 1),
                onLongPress: {}
            )
            Divider()
            MessageSessionRow(
                session: .init(id: "u2", peerNickname: "Bob", peerAvatarURL: nil,
                               lastMessage: "[Image]", lastMessageTimestamp: 0,
                               unreadCount: 0, isTop: false, ext: .empty),
                profile: nil,
                onLongPress: {}
            )
        }
        .previewLayout(.sizeThatFits)
    }
}
#endif
