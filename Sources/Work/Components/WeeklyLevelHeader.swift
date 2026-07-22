import SwiftUI

/// 顶部周等级区。对齐 H5 work/index.vue 头像区 + 等级区：
/// 第一行：头像圆环 32×32（渐变环）+ 内头像 28×28  |  "Weekly Level SS" pill（双层渐变+边框）
/// 第二行：场景文案（getLevelText）  |  Detail 按钮
/// 第三行：彩虹进度条（h=10）
/// 第四行：段位刻度 D C NEW B A S SS（每段独立品牌色）
struct WeeklyLevelHeader: View {
    @ObservedObject var vm: WorkViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 第一行：头像 + Weekly Level pill
            HStack(spacing: 10) {
                avatar
                levelPill
                Spacer(minLength: 0)
            }
            .padding(.bottom, 4)

            // 第二行：场景文案 + Detail
            HStack(alignment: .center, spacing: 10) {
                Text(vm.levelText)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                detailPill
            }

            // 第三行：彩虹进度条（H5 h-10 rounded-10）
            Capsule()
                .fill(LinearGradient(
                    colors: [Color(hex: 0x33FFF7), Color(hex: 0xFA06F4), Color(hex: 0xFFE600)],
                    startPoint: .leading, endPoint: .trailing
                ))
                .frame(height: 10)
                .padding(.top, 2)
                .accessibilityHidden(true)

            // 第四行：段位刻度（H5 justify-around，7 段独立颜色）
            tierRow
        }
    }

    // MARK: - 头像圆环（H5 linear-gradient(147deg,#e40132,#ffe600) 32×32，内 28×28）
    private var avatar: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color(hex: 0xE40132), Color(hex: 0xFFE600)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 32, height: 32)

            AvatarView(url: vm.avatarURL, size: 28, kind: .anchor, persistent: true)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Weekly Level pill（H5 双层背景 + 亮色边框，高 30，rounded 12）
    private var levelPill: some View {
        HStack(spacing: 5) {
            Text(L10n.workWeeklyLevel)
                .font(.system(size: 12))
                .foregroundStyle(.white)
            Text(vm.weeklyLevel)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(color(forLevel: vm.weeklyLevel))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        // padding-box: linear-gradient(90deg, #E40132, #6021BD)
        .background(
            LinearGradient(
                colors: [Color(hex: 0xE40132), Color(hex: 0x6021BD)],
                startPoint: .leading, endPoint: .trailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // border-box: linear-gradient(90deg, #FF0026, #FF0088) 1pt
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color(hex: 0xFF0026), Color(hex: 0xFF0088)],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Detail 小 pill（H5 border 半透白，rounded 20，text 10）
    private var detailPill: some View {
        NavigationLink(value: WorkRoute.dataStatistics) {
            HStack(spacing: 3) {
                Text(L10n.workDetail)
                    .font(.system(size: 10))
                Image(systemName: "chevron.forward")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Color.white.opacity(0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(
                Capsule().stroke(Color.white.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.workDetail)
    }

    // MARK: - 段位刻度
    private var tierRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(vm.tiers.enumerated()), id: \.offset) { index, tier in
                Text(tier)
                    .font(.system(size: 12))
                    .foregroundStyle(color(forLevel: tier))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// 段位色（H5 getLevelColor 完全对齐）
    private func color(forLevel level: String) -> Color {
        switch level {
        case "SS":  return Color(hex: 0xFEE501)
        case "S":   return Color(hex: 0xFD8965)
        case "A":   return Color(hex: 0xFB4DA6)
        case "B":   return Color(hex: 0xFB0FEB)
        case "NEW": return Color(hex: 0xBC53F5)
        case "C":   return Color(hex: 0x7CA2F5)
        case "D":   return Color(hex: 0x32F1EA)
        default:    return .white
        }
    }
}
