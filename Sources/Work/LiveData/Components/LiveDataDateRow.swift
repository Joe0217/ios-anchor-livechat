import SwiftUI

/// 日期列表单行：日期 / 时长 / 收益 + 展开 → live/private 分档。
/// 对齐 H5 `liveData/index.vue:314-387`。expanded 态从 Store 读取（statDate 为 key），
/// 让每次 reload 成功后展开态清空（对齐 H5 `item.openStatus = false`）。
struct LiveDataDateRow: View {
    let day: LiveDataDay
    let isExpanded: Bool
    let onToggle: () -> Void
    /// v2 code-review：观察 canCall 让 Private Call Income 分项显隐响应 permission 变化
    @ObservedObject private var permission = SelfPermissionBridge.shared

    var body: some View {
        VStack(spacing: 0) {
            headerRow
                .padding(.horizontal, 12)
                .padding(.top, 20)
                .padding(.bottom, isExpanded ? 8 : 10)

            if isExpanded {
                breakdown
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Theme.Palette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // 展开动画 0.2s —— 用户反馈"速度快一点"（H5 CSS 原 0.5s 手感偏拖沓）
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            cell(top: day.statDate.isEmpty ? "-" : day.statDate,
                 topColor: .white,
                 label: L10n.commonDate)

            cell(top: LiveDataFormatter.hhmmss(day.totalDurationSeconds),
                 topColor: .white,
                 label: L10n.liveDataLiveDuration)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image("coins")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                    Text("\(day.totalIncomeDiamonds)")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(hex: 0xF9991A))
                }
                Text(L10n.commonIncome)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onToggle) {
                // SF Symbol 圆填充 chevron —— 保证图标始终显示（用户反馈 §4）
                Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color(hex: 0xFFE600))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func cell(top: String, topColor: Color, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(top)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(topColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: breakdown
    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 尖角（对齐 H5 line 352-354 `blackTriangle.webp`）—— 与 SummaryCard 对称
            Image("blackTriangle")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 10)
                .padding(.trailing, 20)
                .frame(maxWidth: .infinity, alignment: .trailing)

            HStack(spacing: 12) {
                item(value: day.liveIncomeDiamonds, label: L10n.liveDataLiveIncome)
                // P 项目权限管理 v2：canCall=false 时隐 Private Call Income（仅 canLive=true+canCall=false 组合可达）
                if permission.canCall {
                    item(value: day.privateCallIncomeDiamonds, label: L10n.liveDataPrivateCallIncome)
                }
            }
            .padding(20)  // 对齐 H5 line 356 `p-20`
            .frame(maxWidth: .infinity)
            .background(Color(hex: 0x191423))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func item(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image("coins")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                Text("\(value)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
            }
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
