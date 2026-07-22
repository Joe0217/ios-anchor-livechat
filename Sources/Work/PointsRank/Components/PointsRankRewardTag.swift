import SwiftUI

/// 排行榜奖励小标签。对齐 H5 [`rewardTag.vue`](../../../../../Desktop/HN/anchor-livechat-h5/src/views/pointsRank/rewardTag.vue)。
/// 小胶囊:钻石 icon + 奖励数值,棕/金渐变底色。
struct PointsRankRewardTag: View {
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image("diamondYellow")
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(Color(hex: 0x5D1C00).opacity(0.5))
        .clipShape(Capsule())
    }
}
