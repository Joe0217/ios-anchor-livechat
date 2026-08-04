import SwiftUI

/// Contribution 单条排名 row（对齐 H5 liveContributionPop.vue Ranking Tab item）
struct ContributionRankRow: View {
    let entry: ContributionEntry
    let onUserTap: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            rankBadge

            Button { onUserTap(entry.userId) } label: {
                AvatarView(urlString: entry.avatarUrl,
                           size: 40,
                           kind: .user,
                           userId: entry.userId,
                           disablesTap: true)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.nickname)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if entry.level > 0 { UserLevelBadge(level: entry.level, size: .small) }
                    if entry.isVip { VIPBadge(size: .small) }
                    if let country = entry.countryId, !country.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "location.fill")
                                .font(.system(size: 9))
                            Text(country)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.white.opacity(0.5))
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    CDNAssetImage("coins")
                        .resizable().frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    Text(formatDiamond(entry.thisLiveDiamond))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: 0xFFE600))
                }
                HStack(spacing: 3) {
                    Text(L10n.liveRoomContributionLast90d)
                    CDNAssetImage("coins")
                        .resizable().frame(width: 12, height: 12)
                    Text(formatDiamond(entry.last90DaysDiamond))
                }
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
            case 1: Image(systemName: "crown.fill").foregroundColor(Color(hex: 0xFFBB02))
            case 2: Image(systemName: "crown.fill").foregroundColor(Color(hex: 0xC0C0C0))
            case 3: Image(systemName: "crown.fill").foregroundColor(Color(hex: 0xCD7F32))
            default: Text("\(entry.rank)").foregroundColor(Color(hex: 0xA56FF8))
            }
        }
        .font(.system(size: 16, weight: .heavy))
        .frame(width: 28, alignment: .center)
    }

    private func formatDiamond(_ n: Int64) -> String {
        if n >= 1_000_000 { return String(format: "%.1fm", floor(Double(n) / 100_000) / 10) }
        if n >= 1_000 { return String(format: "%.1fk", floor(Double(n) / 100) / 10) }
        return "\(n)"
    }
}

/// Contribution 礼物记录 row（对齐 H5 liveContributionPop.vue Record Tab item）
struct GiftRecordRow: View {
    let record: GiftRecord
    let onUserTap: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button { onUserTap(record.userId) } label: {
                AvatarView(urlString: record.userAvatarUrl,
                           size: 32,
                           kind: .user,
                           userId: record.userId,
                           disablesTap: true)
            }
            .buttonStyle(.plain)

            Text(record.userNickname)
                .font(.system(size: 16))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(maxWidth: 120, alignment: .leading)

            Spacer(minLength: 8)

            Text(displayTime)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 4) {
                CachedAsyncImage(url: record.giftIconUrl.flatMap(URL.init(string:)), contentMode: .fit, cdn: (.gift, .fit)) {
                    Image(systemName: "gift.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundColor(Color(hex: 0xFFE600))
                }
                .frame(width: 28, height: 28)
                Text("x \(record.quantity)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var displayTime: String {
        if let formatted = record.formattedTime, !formatted.isEmpty { return formatted }
        return formatRelativeTime(record.time)
    }

    private func formatRelativeTime(_ ms: Int64) -> String {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let diff = (now - ms) / 1000   // seconds
        if diff < 60 { return "\(diff)s" }
        if diff < 3600 { return "\(diff / 60)m" }
        return "\(diff / 3600)h"
    }
}
