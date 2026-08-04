import SwiftUI

/// 三项概览卡：在线时长 / 平均通话时长 / 好评率。对齐 H5 work/index.vue。
/// P 项目权限管理 v2：`canCall=false` 时剔除 Avg Call Duration（属通话数据），HStack 自动 2 卡等宽。
struct StatCardsRow: View {
    @ObservedObject var vm: WorkViewModel
    /// P 项目权限管理：观察 canCall 决定是否显示 Avg Call Duration 卡
    @ObservedObject private var permission = SelfPermissionBridge.shared

    var body: some View {
        HStack(spacing: Theme.Metric.statCardGap) {
            // 数字色对齐图标主色（用户 UI 反馈 §3）：
            // - Online Time 图标是橙红时钟 → 橙红数值
            // - Avg Call Duration 图标是青绿电话 → 青绿数值
            // - Positive Rating 图标是粉紫笑脸 → 粉紫数值
            StatCard(icon: "statOnlineTime",
                     number: Self.timeString(vm.onlineTimeSec),
                     numberColor: Color(hex: 0xFF7A2C),
                     caption: L10n.workOnlineTime)
            if permission.canCall {
                StatCard(icon: "statAvgCallDuration",
                         number: Self.timeString(vm.avgCallDurationSec),
                         numberColor: Color(hex: 0x00D6C4),
                         caption: L10n.workAvgCallDuration)
            }
            StatCard(icon: "statRating",
                     number: "\(vm.positiveRating)%",
                     numberColor: Color(hex: 0xF640DC),
                     caption: L10n.workPositiveRating)
        }
    }

    /// HH:MM:SS（H5 secondsToTime 同格式），秒对齐"padStart(2,'0')"
    private static func timeString(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }
}

private struct StatCard: View {
    let icon: String
    let number: String
    let numberColor: Color
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.statNumberToCaption) {
            // 图标独占顶行
            CDNAssetImage(icon)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)

            // 大数字（色对齐图标主色）
            Text(number)
                .font(Theme.Typography.bigStat)
                .foregroundStyle(numberColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            // 次级文案 10pt 位于数字下方
            Text(caption)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(Theme.Metric.cardPadding)
        .background(Theme.Palette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.statCard, style: .continuous))
    }
}
