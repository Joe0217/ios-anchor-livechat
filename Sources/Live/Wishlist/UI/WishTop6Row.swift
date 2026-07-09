import SwiftUI

/// Top6 贡献者头像榜（对齐 H5 wishlist-anchor-panel.vue Top Gifters 区）
///
/// 6 个头像槽位；Top 1-3 有金/银/铜皇冠，Top 4-6 无
struct WishTop6Row: View {
    let gifters: [WishlistTop6Item]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: 0xFFBB02))
                Text(L10n.wishlistTop6Title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
            }

            HStack(spacing: 8) {
                ForEach(gifters) { g in
                    slot(g)
                }
            }

            Text(L10n.wishlistTop6Empty)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private func slot(_ g: WishlistTop6Item) -> some View {
        VStack(spacing: 4) {
            ZStack {
                if g.isEmpty {
                    Circle().fill(Color.white.opacity(0.08)).frame(width: 48, height: 48)
                } else {
                    AvatarView(urlString: g.avatarUrl, size: 48, kind: .user)
                }
                // Top 1-3 皇冠角标
                if !g.isEmpty && g.rank <= 3 {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "crown.fill")
                                .font(.system(size: 12))
                                .foregroundColor(crownColor(g.rank))
                        }
                        Spacer()
                    }
                    .frame(width: 48, height: 48)
                }
            }
            Text(g.isEmpty ? "--" : formatDiamond(g.totalDiamond))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(g.isEmpty ? .white.opacity(0.4) : Color(hex: 0xFFE600))
        }
    }

    private func crownColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return Color(hex: 0xFFBB02)
        case 2: return Color(hex: 0xC0C0C0)
        case 3: return Color(hex: 0xCD7F32)
        default: return .white
        }
    }

    private func formatDiamond(_ n: Int64) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000.0) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000.0) }
        return "\(n)"
    }
}
