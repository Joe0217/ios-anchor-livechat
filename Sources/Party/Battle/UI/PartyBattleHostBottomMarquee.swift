import SwiftUI

/// PK RUNNING 阶段底部红蓝 Top3 头像跑马灯（对齐 H5 hostBottomMarquee.vue 166 行）
///
/// 视觉结构：
/// - 左红队 Top3 头像（rank 1 靠中央，reverse 排列）
/// - 中央 PK 对战 icon
/// - 右蓝队 Top3 头像（rank 1 靠中央，正序）
/// - rank 1/2/3 边框色：金 / 深蓝 / 棕铜
/// - rank 1/2/3 右下角 n1/n2/n3 角标（占位数字圆点）
/// - 不足 3 项 placeholder 补位（灰色空 avatar）
struct PartyBattleHostBottomMarquee: View {
    @ObservedObject var store: PartyBattleStore

    /// 排名 1/2/3 头像边框色（H5 :14 RANK_BORDER）
    private let rankBorders: [Color] = [
        Color(red: 1.0, green: 0.73, blue: 0.01),   // #FFBB02 金
        Color(red: 0.0, green: 0.36, blue: 0.78),   // #005DC8 深蓝
        Color(red: 0.58, green: 0.35, blue: 0.28),  // #935848 棕铜
    ]

    var body: some View {
        HStack(spacing: 0) {
            // 左红队：justify-end + reverse（rank 1 靠中央）
            HStack(spacing: 4) {
                Spacer()
                ForEach(Array(redAvatars.enumerated().reversed()), id: \.offset) { pair in
                    avatarItem(item: pair.element, side: .red)
                }
                Image(systemName: "arrow.right")
                    .foregroundColor(.white.opacity(0.5))
                    .font(.footnote)
                    .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity)
            .background(redStripBg)

            Image("partyPkBattleMarker")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
            .zIndex(1)

            // 右蓝队：justify-start（正序，rank 1 在左靠中央）
            HStack(spacing: 4) {
                Image(systemName: "arrow.left")
                    .foregroundColor(.white.opacity(0.5))
                    .font(.footnote)
                    .padding(.horizontal, 8)
                ForEach(Array(blueAvatars.enumerated()), id: \.offset) { pair in
                    avatarItem(item: pair.element, side: .blue)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(blueStripBg)
        }
        .frame(height: 32)
        .background(centerStripBg)
    }

    // MARK: - Sub-views

    private enum Side { case red, blue }

    @ViewBuilder
    private func avatarItem(item: MarqueeItem, side: Side) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 28, height: 28)
                .overlay(
                    Group {
                        if item.isPlaceholder {
                            Image(systemName: "person.fill")
                                .foregroundColor(.white.opacity(0.3))
                        } else {
                            // Top3 头像走公共 CachedAsyncImage（他人头像 persistent=false）
                            CachedAsyncImage(
                                url: URL(string: item.avatar ?? ""),
                                contentMode: .fill,
                                persistent: false,
                                cdn: (.avatarSmall, .fill)
                            ) {
                                Image(systemName: "person.fill").foregroundColor(.white.opacity(0.5))
                            }
                            .frame(width: 28, height: 28)
                        }
                    }
                    .clipShape(Circle())
                )
                .overlay(
                    Circle().stroke(
                        item.isPlaceholder ? Color.clear : rankBorders[safe: item.rankIdx] ?? .clear,
                        lineWidth: 1.5
                    )
                )

            // rank 1/2/3 角标（H5 n1.webp/n2.webp/n3.webp；iOS 用数字圆点占位）
            if !item.isPlaceholder {
                Text("\(item.rankIdx + 1)")
                    .font(.system(size: 9)).bold()
                    .foregroundColor(.white)
                    .frame(width: 12, height: 12)
                    .background(rankBorders[safe: item.rankIdx] ?? .gray)
                    .clipShape(Circle())
                    .offset(x: 3, y: 2)
            }
        }
        .zIndex(Double(10 - item.rankIdx))
    }

    // MARK: - Data build

    private struct MarqueeItem {
        let uid: Int64
        let nickname: String?
        let avatar: String?
        let rankIdx: Int
        let isPlaceholder: Bool
    }

    /// H5 :28-36 buildTop3 逻辑：过滤 senderUid>0 && diamonds>0 → slice(0,3) → 不足补 placeholder
    private func buildTop3(_ items: [BattleTopMember]) -> [MarqueeItem] {
        var list: [MarqueeItem] = items
            .filter { $0.uid > 0 && $0.diamondsValue > 0 }
            .prefix(3)
            .map { m in
                MarqueeItem(
                    uid: m.uid, nickname: m.nickname, avatar: m.avatar,
                    rankIdx: m.rankIdx, isPlaceholder: false)
            }
        while list.count < 3 {
            list.append(MarqueeItem(uid: 0, nickname: nil, avatar: nil, rankIdx: list.count, isPlaceholder: true))
        }
        return list
    }

    private var redAvatars: [MarqueeItem] { buildTop3(store.state?.redTop ?? []) }
    private var blueAvatars: [MarqueeItem] { buildTop3(store.state?.blueTop ?? []) }

    // MARK: - Style

    private var redStripBg: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.97, green: 0.09, blue: 0.62).opacity(0.5),
                Color(red: 0.97, green: 0.09, blue: 0.62).opacity(0.0),
            ],
            startPoint: .leading, endPoint: .trailing)
    }

    private var blueStripBg: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.06, green: 0.41, blue: 0.98).opacity(0.0),
                Color(red: 0.06, green: 0.41, blue: 0.98).opacity(0.5),
            ],
            startPoint: .leading, endPoint: .trailing)
    }

    private var centerStripBg: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.97, green: 0.09, blue: 0.62).opacity(0.5),
                Color(red: 0.97, green: 0.09, blue: 0.62).opacity(0.1),
                Color(red: 0.06, green: 0.41, blue: 0.98).opacity(0.1),
                Color(red: 0.06, green: 0.41, blue: 0.98).opacity(0.5),
            ],
            startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - Safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
