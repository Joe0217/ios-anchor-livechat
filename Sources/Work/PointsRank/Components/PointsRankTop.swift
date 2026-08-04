import SwiftUI

/// Top3 领奖台。对齐 H5 [`top.vue`](../../../../../Desktop/HN/anchor-livechat-h5/src/views/pointsRank/top.vue)。
///
/// **顺序**:HStack 排列 [2nd, 1st, 3rd] —— 1st 居中,视觉重点。
/// **不规则高度**:第 2 位 `mt-40 h-190` / 第 1 位 `mt-20 h-223` / 第 3 位 `mt-60 h-180`,
/// 即 1 位居中稍高稍低 mt,视觉上呈"高、更高、低"金字塔。
///
/// 每项:王冠 icon(3 色区分)+ 圆头像 + top 标 + 昵称 + integral + reward pill。
struct PointsRankTop: View {
    /// 3 个位置的 items:[2nd, 1st, 3rd](调用方按 H5 顺序传入)
    let items: [PointsRankItemVO?]

    /// 每个位置对应的实际排名(顺序对齐 items):[2, 1, 3]
    private let rankLabels = [2, 1, 3]

    var body: some View {
        ZStack(alignment: .top) {
            CDNAssetImage("homePointsPodium")
                .resizable()
                .scaledToFit()
                .frame(width: 375)
                .offset(y: 50)

            HStack(alignment: .top, spacing: 0) {
                ForEach(0..<3, id: \.self) { i in
                    cell(index: i, item: items[i], rank: rankLabels[i])
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: 250)
    }

    private func cell(index: Int, item: PointsRankItemVO?, rank: Int) -> some View {
        // 高度差异对齐 H5:1 位居中 223pt(index=1),2 位 190pt(index=0),3 位 180pt(index=2)
        let cellHeight: CGFloat = index == 0 ? 190 : (index == 1 ? 223 : 180)
        let topOffset: CGFloat = index == 0 ? 40 : (index == 1 ? 20 : 60)

        let crown = rank == 1 ? "homePointsTop1" : rank == 2 ? "homePointsTop2" : "homePointsTop3"
        return ZStack(alignment: .top) {
            AvatarView(url: URL(string: item?.icon ?? ""), size: 60, kind: .user, disablesTap: true)
                .overlay(Circle().stroke(Color.red, lineWidth: 2))

            CDNAssetImage(crown)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .offset(x: 32, y: -20)

            VStack(spacing: 5) {
                Text("top \(rank)")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color(hex: 0xFFE600))
                Text(item?.nickname ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 2) {
                    CDNAssetImage("homeRankIntegral").resizable().scaledToFit().frame(width: 16, height: 16)
                    Text("\(item?.integralAmount ?? 0)")
                }
                .font(.system(size: 12))
                .foregroundStyle(.white)
                if let reward = item?.reward, !reward.isEmpty {
                    PointsRankRewardTag(text: reward)
                }
            }
            .padding(.top, 80)
        }
        .frame(width: 112, height: cellHeight, alignment: .top)
        .padding(.top, topOffset)
        .offset(x: index == 0 ? 20 : index == 2 ? -20 : 0)
    }
}
