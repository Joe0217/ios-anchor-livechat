import SwiftUI

/// B-8 · PK 对战底部 Top3 贡献者（严格对齐 H5 pkBattleViewTop3Contributors.vue 2026-07-06）。
///
/// H5 视觉（template L98-242）：
/// - **整体 32pt 高横条**，左右各占 flex-1
/// - **左侧我方**：粉色横向渐变背景 `#F8179D 20%→0%`；内层反向 flex-row-reverse（从右往左）：箭头 → Top1 → Top2 → Top3
/// - **右侧对方**：蓝色横向渐变 `#1068FA 0%→20%`；内层正向 flex：箭头 ← Top1 → Top2 → Top3
/// - 头像 28pt 圆，**并排 gap-8pt 不叠加**，边框 1pt 按排名分色：
///   - Top1（idx 0）→ `#FFBB02` 金黄
///   - Top2（idx 1）→ `#005DC8` 深蓝
///   - Top3（idx 2）→ `#935848` 棕
/// - Rank icon 12pt 位于每个头像**右下角**（`absolute bottom--6 right-0`）
/// - 空数据 → 显示单个 Top1 位（金黄边框 + 灰圆占位 + top1 rank icon）
///
/// **iOS 侧 rank icon 切图缺失**（H5 用 icon-top3-1/2/3.webp）：
/// - Top1 → SF Symbol `crown.fill` 金黄（近似 icon-top3-1）
/// - Top2 → `pkBattleRank2` 切图（Frame 1171275841 蓝色 "2"，对应 icon-top3-2）
/// - Top3 → `pkBattleRank3` 切图（Frame 1171275842 棕色 "3"，对应 icon-top3-3）
struct PKBattleTop3Contributors: View {
    let myTop3: [PKTopUser]
    let opponentTop3: [PKTopUser]

    private let avatarSize: CGFloat = 28
    private let rankIconSize: CGFloat = 12

    var body: some View {
        HStack(spacing: 0) {
            // 我方（左）：粉色横向渐变，内层反向排列（从右往左 top1/2/3）
            side(users: myTop3,
                 gradient: LinearGradient(colors: [Color(hex: 0xF8179D, opacity: 0.2),
                                                   Color(hex: 0xF8179D, opacity: 0)],
                                          startPoint: .leading, endPoint: .trailing),
                 isMine: true)
                .frame(maxWidth: .infinity)

            // 对方（右）：蓝色横向渐变，内层正向排列
            side(users: opponentTop3,
                 gradient: LinearGradient(colors: [Color(hex: 0x1068FA, opacity: 0),
                                                   Color(hex: 0x1068FA, opacity: 0.2)],
                                          startPoint: .leading, endPoint: .trailing),
                 isMine: false)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 32)
    }

    /// 单侧：外层渐变背景 + 内层头像 row + 箭头
    private func side(users: [PKTopUser], gradient: LinearGradient, isMine: Bool) -> some View {
        gradient
            .overlay(alignment: isMine ? .trailing : .leading) {
                // isMine=true 时内层反向 row（右到左依次是 top1/2/3 + 箭头）
                // isMine=false 时内层正向 row（左到右依次是 箭头 + top1/2/3）
                if isMine {
                    HStack(spacing: 8) {
                        // top3/2/1（反向）
                        ForEach(Array((users.isEmpty ? [nil] : Array(users.prefix(3).map { Optional($0) })).enumerated().reversed()), id: \.offset) { idx, user in
                            avatarSlot(user: user, rank: idx)
                        }
                        arrowIcon(direction: .rightToLeft, hidden: users.isEmpty)
                    }
                    // H5 我方 `pe-8 ps-16` LTR → leading:16 / trailing:8
                    .padding(.leading, 16)
                    .padding(.trailing, 8)
                } else {
                    HStack(spacing: 8) {
                        arrowIcon(direction: .leftToRight, hidden: users.isEmpty)
                        // top1/2/3（正向）
                        ForEach(Array((users.isEmpty ? [nil] : Array(users.prefix(3).map { Optional($0) })).enumerated()), id: \.offset) { idx, user in
                            avatarSlot(user: user, rank: idx)
                        }
                    }
                    // H5 对方 `pe-16 ps-8` LTR → leading:8 / trailing:16
                    .padding(.leading, 8)
                    .padding(.trailing, 16)
                }
            }
    }

    /// 单个头像位 + 边框色（按 rank）+ 右下 rank icon
    @ViewBuilder
    private func avatarSlot(user: PKTopUser?, rank: Int) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let user {
                    AvatarView(urlString: user.displayAvatar, size: avatarSize, kind: .user)
                } else {
                    // 2026-07-07 v5：空占位灰圆 → defaultUserAvatar（对齐 H5 icon-top-empty.webp 意图）
                    Image("defaultUserAvatar")
                        .resizable()
                        .frame(width: avatarSize, height: avatarSize)
                        .clipShape(Circle())
                }
            }
            .overlay(Circle().stroke(borderColor(rank), lineWidth: 1))

            // 右下角 rank icon（H5 `absolute bottom--6 right-0` = 悬出 avatar 右下 6pt）
            rankIcon(rank: rank)
                .offset(x: 4, y: 4)
        }
        .accessibilityElement(children: .combine)
    }

    /// 边框色（Top1 金 / Top2 深蓝 / Top3 棕）
    private func borderColor(_ rank: Int) -> Color {
        switch rank {
        case 0: return Color(hex: 0xFFBB02)
        case 1: return Color(hex: 0x005DC8)
        case 2: return Color(hex: 0x935848)
        default: return Color(hex: 0xFFBB02)
        }
    }

    /// Rank icon（切图组合，用户 2026-07-07 v5 明示"应该是 MVP 图标"）：
    /// - Top1 → `pkBattleMVP`（金色 MVP 徽章）
    /// - Top2/3 → `pkBattleRank2/3`（保持切图）
    @ViewBuilder
    private func rankIcon(rank: Int) -> some View {
        switch rank {
        case 0:
            Image("pkBattleMVP")
                .resizable()
                .frame(width: rankIconSize, height: rankIconSize)
                .accessibilityHidden(true)
        case 1:
            Image("pkBattleRank2")
                .resizable()
                .frame(width: rankIconSize, height: rankIconSize)
                .accessibilityHidden(true)
        case 2:
            Image("pkBattleRank3")
                .resizable()
                .frame(width: rankIconSize, height: rankIconSize)
                .accessibilityHidden(true)
        default:
            EmptyView()
        }
    }

    /// 箭头（点击进入排行榜的指示），空数据时透明占位
    private enum ArrowDir { case leftToRight, rightToLeft }
    private func arrowIcon(direction: ArrowDir, hidden: Bool) -> some View {
        Image(systemName: direction == .leftToRight ? "chevron.left" : "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(hidden ? .clear : .white.opacity(0.4))
            .accessibilityHidden(true)
    }
}
