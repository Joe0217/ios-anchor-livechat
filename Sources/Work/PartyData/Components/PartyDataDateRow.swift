import SwiftUI

/// Party Data 日期列表单行：日期 / 麦时(可点击) / 收益 + 展开 → Party Room Gift / Partycall 分档。
/// 视觉镜像 [LiveDataDateRow]；差异：
/// - 麦时可点击（点 → 父层弹麦时二级页 sheet，带 statDate）
/// - 展开分档 2 项：Party Room Gift + Partycall（后者合并 partyCallGems+partyCallGiftGems）
struct PartyDataDateRow: View {
    let day: PartyRoomDaily
    let isExpanded: Bool
    let onToggle: () -> Void
    let onMicTimeTap: () -> Void

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
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            cell(top: day.statDate.isEmpty ? "-" : day.statDate,
                 topColor: .white,
                 label: L10n.commonDate)

            // 麦时（可点击）
            Button(action: onMicTimeTap) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text(LiveDataFormatter.hhmmss(day.micTimeSeconds))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Text(L10n.partyDataMicTime)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    CDNAssetImage("gems")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                    Text("\(day.totalIncomeGems)")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(hex: 0xF9991A))
                }
                Text(L10n.commonIncome)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onToggle) {
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
            CDNAssetImage("blackTriangle")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 10)
                .padding(.trailing, 20)
                .frame(maxWidth: .infinity, alignment: .trailing)

            HStack(spacing: 12) {
                item(value: day.incomeBreakdown.partyRoomGiftGems,
                     label: L10n.partyDataGiftIncome)
                item(value: day.incomeBreakdown.partyCallTotalGems,
                     label: L10n.partyDataCallIncome)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Color(hex: 0x191423))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func item(value: Int, label: String) -> some View {
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
