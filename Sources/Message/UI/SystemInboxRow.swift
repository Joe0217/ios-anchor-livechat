import SwiftUI

/// Flame tab 顶部 3 系统消息入口行（H-1c v4，对齐 H5 `list.vue:264-345`）。
///
/// **无业务态**：entry + tap 回调由父注入。视觉与 `MessageSessionRow` 同尺寸，图标用 SF Symbol
/// 占位（H-2 期换 station-icon.webp / system-icon.webp / admin-icon.webp 真图标）。
struct SystemInboxRow: View {

    let entry: SystemInboxEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                iconView
                mainInfo
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    private var iconView: some View {
        Circle()
            .fill(iconBg)
            .frame(width: 48, height: 48)
            .overlay(
                Image(systemName: iconName)
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }

    private var iconName: String {
        switch entry.kind {
        case .station:      return "envelope.fill"
        case .notification: return "bell.fill"
        case .admin:        return "person.crop.circle.badge.questionmark"
        }
    }

    private var iconBg: Color {
        switch entry.kind {
        case .station:      return Color.orange.opacity(0.85)
        case .notification: return Color.blue.opacity(0.85)
        case .admin:        return Color.purple.opacity(0.85)
        }
    }

    private var mainInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(entry.preview)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// 从 kind 派生 i18n 标题（Store 不依赖 L10n；view 层集中查表）。
    private var title: String {
        switch entry.kind {
        case .station:      return L10n.messageSystemInboxStation
        case .notification: return L10n.messageSystemInboxNotification
        case .admin:        return L10n.messageSystemInboxAdmin
        }
    }

    private var trailing: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if entry.updateTime > 0 {
                Text(MessageTimeFormatter.formatTalkTime(entry.updateTime))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if entry.unread > 0 {
                Text(entry.unread > 99 ? "99+" : "\(entry.unread)")
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
        var parts = [title]
        if !entry.preview.isEmpty { parts.append(entry.preview) }
        if entry.unread > 0 { parts.append(L10n.messageA11yUnreadCountFormat(entry.unread)) }
        return parts.joined(separator: ", ")
    }
}
