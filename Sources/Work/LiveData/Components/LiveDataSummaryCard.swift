import SwiftUI

/// 汇总卡：期间标签 + 子期间下拉 + 总时长 / 总收益 + 展开显示 live/private 分档。
/// 对齐 H5 `liveData/index.vue:164-257`。
struct LiveDataSummaryCard: View {
    let dateType: LiveDataDateType
    let totalDurationSeconds: Int
    let totalIncomeDiamonds: Int
    let liveIncomeDiamonds: Int
    let privateCallIncomeDiamonds: Int
    /// tap 下拉按钮回调 —— 父层展示下拉菜单（保持 dropdown 与 card 分离，Sheet/Popover 由父层挂）
    let onDropdownTap: () -> Void
    /// dropdown 打开态（旋转箭头）
    let dropdownExpanded: Bool

    @State private var expandBreakdown = true
    /// v2 code-review：观察 canCall 让 Private Call Income 分项显隐响应 permission 变化
    @ObservedObject private var permission = SelfPermissionBridge.shared

    private var segmentLabel: String {
        switch dateType.segment {
        case .weekly:  return L10n.commonWeekly
        case .monthly: return L10n.commonMonthly
        }
    }

    private var childLabel: String {
        switch dateType {
        case .thisWeek:      return L10n.commonThisWeek
        case .lastWeek:      return L10n.commonLastWeek
        case .thisMonth:     return L10n.commonThisMonth
        case .lastMonth:     return L10n.commonLastMonth
        case .twoMonthsAgo:  return L10n.commonTwoMonthsAgo
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 12)

            // H5 `bg-[#EDEDED] h-1` —— 显式 1pt 高度（默认 Divider 是 hairline ≈0.33pt）
            Rectangle()
                .fill(Color(hex: 0xEDEDED))
                .frame(height: 1)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            totalsRow
                .padding(.horizontal, 12)

            if expandBreakdown {
                breakdownPanel
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.bottom, expandBreakdown ? 0 : 12)
        .background(Theme.Palette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // 展开动画 0.2s —— 用户反馈"速度快一点"（H5 CSS 原 0.5s 手感偏拖沓）
        .animation(.easeInOut(duration: 0.2), value: expandBreakdown)
    }

    // MARK: header
    private var header: some View {
        HStack {
            Text(segmentLabel)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)

            Spacer()

            Button(action: onDropdownTap) {
                HStack(spacing: 6) {
                    Text(childLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                    // SF Symbol chevron —— 避免 imageset 未登记 pbxproj 导致空显示（用户反馈 §4）
                    // 展开态朝上、闭态朝下 —— 与用户直觉一致
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(dropdownExpanded ? 180 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .overlay(
                    Capsule().stroke(.white, lineWidth: 1)
                )
                .frame(minWidth: 100)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: totals row
    private var totalsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            metric(iconName: "pinkClock",
                   value: LiveDataFormatter.hhmmss(totalDurationSeconds),
                   valueColor: Color(hex: 0xF640DC),
                   label: L10n.liveDataTotalDuration)

            metric(iconName: "yellowDiamond",
                   value: "\(totalIncomeDiamonds)",
                   valueColor: Color(hex: 0xF9991A),
                   label: L10n.liveDataTotalIncome)

            Spacer(minLength: 0)

            Button {
                expandBreakdown.toggle()
            } label: {
                // SF Symbol 圆填充 chevron —— 保证图标始终显示（用户反馈 §4）
                // 展开态朝上、闭态朝下；黄色对齐 H5 yellowRoundArrow 视觉
                Image(systemName: expandBreakdown ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color(hex: 0xFFE600))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expandBreakdown ? L10n.liveDataCollapse : L10n.liveDataExpand)
        }
    }

    private func metric(iconName: String,
                        value: String, valueColor: Color,
                        label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(iconName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
            Text(value)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: breakdown panel（live / private call）
    private var breakdownPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 尖角（对齐 H5 `blackTriangle.webp`）—— 用 asset 保 H5 视觉一致
            Image("blackTriangle")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 10)
                .padding(.trailing, 20)
                .frame(maxWidth: .infinity, alignment: .trailing)

            HStack(spacing: 12) {
                breakdownItem(value: liveIncomeDiamonds, label: L10n.liveDataLiveIncome)
                // P 项目权限管理 v2：canCall=false 时隐 Private Call Income（仅 canLive=true+canCall=false 组合可达）
                if permission.canCall {
                    breakdownItem(value: privateCallIncomeDiamonds, label: L10n.liveDataPrivateCallIncome)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Color(hex: 0x191423))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func breakdownItem(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image("diamondYellow")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 10.5)
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
