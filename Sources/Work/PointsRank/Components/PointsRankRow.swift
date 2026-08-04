import SwiftUI

/// 单行排行榜(4 名起)。对齐 H5 [`rankListItem.vue`](../../../../../Desktop/HN/anchor-livechat-h5/src/views/pointsRank/rankListItem.vue)。
///
/// **布局**:64pt 高;左排名数字 + 头像(AvatarView 复用) + 昵称/国旗+国家 + 右侧 integral + reward tag。
struct PointsRankRow: View {
    let item: PointsRankItemVO
    /// 排名(从 4 开始)
    let ranking: Int

    var body: some View {
        HStack(spacing: 0) {
            // 排名数字
            Text("\(ranking)")
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .frame(width: 32, alignment: .center)
                .padding(.trailing, 8)

            // 头像
            AvatarView(url: URL(string: item.icon ?? ""),
                       size: 44,
                       kind: .user,
                       disablesTap: true)

            // 中间:昵称 + 国家
            VStack(alignment: .leading, spacing: 4) {
                Text(item.nickname)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let country = item.countryId, !country.isEmpty {
                    HStack(spacing: 4) {
                        CDNAssetImage("liveListLocation")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12, height: 12)
                        Text(country)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)

            // 右侧:integral + reward tag
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    CDNAssetImage("homeRankIntegral")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                    Text("\(item.integralAmount)")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                }
                if let reward = item.reward, !reward.isEmpty {
                    PointsRankRewardTag(text: reward)
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }
}
