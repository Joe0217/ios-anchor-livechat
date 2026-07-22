import SwiftUI

/// 单条排名 row（对齐 H5 girlWeeklyRank.vue rank + avatar + nickname + level badge + diamond count）
struct RankRow: View {
    let entry: RankEntry
    let onUserTap: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            // 排名徽章：Top1/2/3 高亮色，其余灰白
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                // 等级徽章
                Text("Lv.\(entry.level)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Image("coins")
                    .resizable().frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                Text(formatDiamond(entry.diamond))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: 0xFFE600))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// v13 对齐 H5 userWeeklyRank.vue L384-462：Top1/2/3 皇冠图标 + 4+ 紫色数字带圆背
    @ViewBuilder
    private var rankBadge: some View {
        Group {
            switch entry.rank {
            case 1:
                Image(systemName: "crown.fill")
                    .foregroundColor(Color(hex: 0xFFBB02))
                    .font(.system(size: 20))
            case 2:
                Image(systemName: "crown.fill")
                    .foregroundColor(Color(hex: 0xC0C0C0))
                    .font(.system(size: 18))
            case 3:
                Image(systemName: "crown.fill")
                    .foregroundColor(Color(hex: 0xCD7F32))
                    .font(.system(size: 16))
            default:
                // H5 text-#A56FF8FF 紫色数字（4+ 位次）
                Text("\(entry.rank)")
                    .foregroundColor(Color(hex: 0xA56FF8))
                    .font(.system(size: 16, weight: .heavy))
            }
        }
        .frame(width: 28, alignment: .center)
    }

    /// v13 对齐 H5 userWeeklyRank.vue formatDiamondsNum：<1000 原值 / >=1000 X.Xk（Math.floor(n/100)/10 精度）
    private func formatDiamond(_ n: Int64) -> String {
        if n >= 1000 {
            let k = Double((n / 100)) / 10.0    // 对齐 H5 精度：整除 100 再除 10
            return String(format: "%.1fk", k)
        }
        return "\(n)"
    }
}
