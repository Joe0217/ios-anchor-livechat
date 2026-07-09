import SwiftUI

/// Contribution 单条排名 row（对齐 H5 liveContributionPop.vue Ranking Tab item）
struct ContributionRankRow: View {
    let entry: ContributionEntry

    var body: some View {
        HStack(spacing: 12) {
            rankBadge

            AvatarView(urlString: entry.avatarUrl, size: 40, kind: .user)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.nickname)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("Lv.\(entry.level)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Image("liveRoomDiamondBadge")
                        .resizable().frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    Text(formatDiamond(entry.thisLiveDiamond))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: 0xFFE600))
                }
                Text(String(format: L10n.liveRoomContribution90dFormat, formatDiamond(entry.last90DaysDiamond)))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var rankBadge: some View {
        Group {
            switch entry.rank {
            case 1: Text("1").foregroundColor(Color(hex: 0xFFBB02))
            case 2: Text("2").foregroundColor(Color(hex: 0xC0C0C0))
            case 3: Text("3").foregroundColor(Color(hex: 0xCD7F32))
            default: Text("\(entry.rank)").foregroundColor(.white.opacity(0.6))
            }
        }
        .font(.system(size: 16, weight: .heavy))
        .frame(width: 28, alignment: .center)
    }

    private func formatDiamond(_ n: Int64) -> String {
        if n >= 10_000 { return String(format: "%.1fw", Double(n) / 10_000.0) }
        return "\(n)"
    }
}

/// Contribution 礼物记录 row（对齐 H5 liveContributionPop.vue Record Tab item）
struct GiftRecordRow: View {
    let record: GiftRecord

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(urlString: record.userAvatarUrl, size: 36, kind: .user)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(record.userNickname)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(L10n.liveRoomContributionSentAction)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                HStack(spacing: 4) {
                    Text("\(record.giftName) × \(record.quantity)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Image("liveRoomDiamondBadge")
                        .resizable().frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    Text("\(record.totalDiamond)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: 0xFFE600))
                }
                Text(formatRelativeTime(record.time))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func formatRelativeTime(_ ms: Int64) -> String {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let diff = (now - ms) / 1000   // seconds
        if diff < 60 { return "\(diff)s" }
        if diff < 3600 { return "\(diff / 60)m" }
        return "\(diff / 3600)h"
    }
}
