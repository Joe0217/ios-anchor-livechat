import SwiftUI

/// Party Data 汇总卡：期间标签 + 子期间下拉 + 总麦时（可点击）+ 总收入 + 展开显示分档。
/// 视觉镜像 [LiveDataSummaryCard]；差异：
/// - 收入分档 2 项：**Party Room Gift Income** + **Partycall Income**（后者合并 partyCallGems+partyCallGiftGems, 对齐安卓 :137）
/// - 总麦时可点（点击回调 → 父层弹麦时二级页 sheet）
/// - 无 SelfPermissionBridge（Party Data 不涉及 canCall）
struct PartyDataSummaryCard: View {
    let dateType: PartyDataDateType
    let micTimeSeconds: Int
    let totalIncomeGems: Int
    let incomeBreakdown: PartyIncomeBreakdown
    let onDropdownTap: () -> Void
    let dropdownExpanded: Bool
    /// 总麦时点击回调 —— nil 时无点击态（无数据/error 场景）
    let onMicTimeTap: (() -> Void)?

    @State private var expandBreakdown = true

    private var segmentLabel: String {
        switch dateType.segment {
        case .weekly:  return L10n.commonWeekly
        case .monthly: return L10n.commonMonthly
        }
    }

    private var childLabel: String {
        switch dateType {
        case .thisWeek:  return L10n.commonThisWeek
        case .lastWeek:  return L10n.commonLastWeek
        case .thisMonth: return L10n.commonThisMonth
        case .lastMonth: return L10n.commonLastMonth
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 12)

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
            // 总麦时（可点击 → 弹麦时二级页 sheet）
            Button {
                onMicTimeTap?()
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    CDNAssetImage("pinkClock")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                    HStack(spacing: 4) {
                        Text(LiveDataFormatter.hhmmss(micTimeSeconds))
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(Color(hex: 0xF640DC))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        if onMicTimeTap != nil {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(hex: 0xF640DC))
                        }
                    }
                    Text(L10n.partyDataTotalMicTime)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onMicTimeTap == nil)

            metric(iconName: "gems",
                   value: "\(totalIncomeGems)",
                   valueColor: Color(hex: 0xF9991A),
                   label: L10n.partyDataTotalIncome)

            Spacer(minLength: 0)

            Button {
                expandBreakdown.toggle()
            } label: {
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
            CDNAssetImage(iconName)
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

    // MARK: breakdown panel（Party Room Gift + Partycall 合并）
    private var breakdownPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            CDNAssetImage("blackTriangle")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 10)
                .padding(.trailing, 20)
                .frame(maxWidth: .infinity, alignment: .trailing)

            HStack(spacing: 12) {
                breakdownItem(value: incomeBreakdown.partyRoomGiftGems,
                              label: L10n.partyDataGiftIncome)
                breakdownItem(value: incomeBreakdown.partyCallTotalGems,
                              label: L10n.partyDataCallIncome)
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
                CDNAssetImage("gems")
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
