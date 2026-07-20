import SwiftUI

/// 通话历史记录单行 —— 对齐 H5 `views/communication/records/list.vue` template。
///
/// **布局**（左→右）：
/// - 头像（tap 走 avatarProfilePusher 分派跳详情）
/// - 主信息栏：昵称 + 等级/VIP badge + 来源标签 + 通话状态胶囊
/// - 时间戳（底部一行）
///
/// **昵称颜色**：missedReason == success → 白色；否则红色（H5 `text-color-red`）
/// **状态胶囊**：
/// - success → 绿色底 + 呼入/呼出 icon + duration（HH:mm:ss / mm:ss）
/// - missed  → 红色底 + 呼入/呼出 icon + reason（Rejected/Timeout/Canceled）
struct CallRecordRow: View {

    let record: CallRecord
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                avatar
                mainInfo
                Spacer(minLength: 0)
            }

            Text(formatTimestamp(record.createTime))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.leading, 60)   // 与头像右侧对齐
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    // MARK: - Components

    private var avatar: some View {
        // AvatarView 内置头像 tap → push UserProfileRoute（本项目通用能力）
        AvatarView(urlString: record.icon, size: 48, kind: .user, userId: record.userId)
    }

    private var mainInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 昵称行：色随成功/未接切换（对齐 H5）
            Text(record.nickname)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(record.isSuccess ? Color.white : Color(hex: 0xF30034))
                .lineLimit(1)

            // 等级 + VIP badge 行（对齐 H5 条件：等级不为 "0" 或 VIP 有效时才显示）
            if record.showsLevelBadge || record.isVIPActive {
                HStack(spacing: 4) {
                    if record.showsLevelBadge, let name = record.userLevelName {
                        UserLevelBadge(levelName: name)
                    }
                    if record.isVIPActive {
                        VIPBadge(size: .small)
                    }
                }
            }

            // 来源 tag + 通话状态胶囊
            HStack(spacing: 6) {
                sourceTag
                statusPill
            }
        }
    }

    // MARK: - Source tag（对齐 H5 source() 三档配色）

    private var sourceTag: some View {
        let (text, textColor, bg) = sourceStyle
        return Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(textColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(bg, in: RoundedRectangle(cornerRadius: 4))
    }

    private var sourceStyle: (String, Color, Color) {
        switch record.source {
        case .match:
            return (L10n.callRecordSourceMatch,
                    Color(hex: 0xFF358D),
                    Color(hex: 0xFF358D).opacity(0.20))
        case .liveCall:
            return (L10n.callRecordSourceLive,
                    Color(hex: 0xFF6B31),
                    Color(hex: 0xFF6B31).opacity(0.18))
        case .privateCall:
            return (L10n.callRecordSourcePrivate,
                    Color(hex: 0xA165FF),
                    Color(hex: 0x8131FF).opacity(0.30))
        }
    }

    // MARK: - Status pill（success = 绿 + duration；missed = 红 + reason）

    private var statusPill: some View {
        HStack(spacing: 3) {
            directionIcon
            Text(statusText)
                .font(.system(size: 12))
                .foregroundStyle(statusColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(statusBackground, in: RoundedRectangle(cornerRadius: 5))
    }

    /// 通话方向 icon 名 —— 呼入 → arrow.down.left / 呼出 → arrow.up.right（SF Symbol，
    /// 视觉与 H5 callIn/callOut 语义等价）；未接一律 phone.down.fill
    private var directionIconName: String {
        guard record.isSuccess else { return "phone.down.fill" }
        switch record.direction {
        case .incoming: return "phone.arrow.down.left.fill"
        case .outgoing: return "phone.arrow.up.right.fill"
        }
    }

    private var directionIcon: some View {
        Image(systemName: directionIconName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(statusColor)
    }

    private var statusText: String {
        if record.isSuccess {
            return formatDuration(record.duration)
        }
        switch record.missedReason {
        case .rejected: return L10n.callRecordReasonRejected
        case .timeout:  return L10n.callRecordReasonTimeout
        case .canceled: return L10n.callRecordReasonCanceled
        case .success:  return formatDuration(record.duration)   // 兜底不可达
        }
    }

    private var statusColor: Color {
        record.isSuccess ? Color(hex: 0x22D956) : Color(hex: 0xF30034)
    }

    private var statusBackground: Color {
        record.isSuccess
            ? Color(hex: 0x21E057).opacity(0.20)
            : Color(hex: 0xEB1241).opacity(0.20)
    }

    // MARK: - Formatting

    /// 时长格式化 —— 对齐 H5 duration()：≥1h → HH : mm : ss；<1h → mm : ss
    private func formatDuration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%02d : %02d : %02d", h, m, sec)
        }
        return String(format: "%02d : %02d", m, sec)
    }

    /// 时间戳格式化 —— 对齐 H5 formatTimestamp(ms, "YYYY-mm-dd HH:mm:ss")
    private func formatTimestamp(_ millis: Int64) -> String {
        guard millis > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.string(from: date)
    }

    // MARK: - Accessibility

    private var a11yLabel: String {
        var parts: [String] = [record.nickname]
        parts.append(sourceStyle.0)
        parts.append(statusText)
        if !record.isSuccess {
            parts.append(L10n.callRecordA11yMissed)
        }
        return parts.joined(separator: ", ")
    }
}

#if DEBUG
struct CallRecordRow_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 0) {
            preview(missed: 4, source: "matchV4", incoming: true, duration: 125)
            Divider().background(Color.white.opacity(0.1))
            preview(missed: 1, source: "liveCall", incoming: false, duration: 0)
            Divider().background(Color.white.opacity(0.1))
            preview(missed: 2, source: "private", incoming: true, duration: 0)
        }
        .padding()
        .background(Color(hex: 0x0B0010))
        .preferredColorScheme(.dark)
    }

    private static func preview(missed: Int, source: String, incoming: Bool, duration: Int) -> some View {
        let json: [String: Any] = [
            "userId": "u1",
            "nickname": "Alice",
            "userLevelName": "35",
            "vipExpireTime": Int64((Date().timeIntervalSince1970 + 86400) * 1000),
            "source": source,
            "missedReason": missed,
            "callerUserType": incoming ? 1 : 2,
            "duration": duration,
            "createTime": Int64(Date().timeIntervalSince1970 * 1000),
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let record = try! JSONDecoder().decode(CallRecord.self, from: data)
        return CallRecordRow(record: record, onTap: {})
    }
}
#endif
