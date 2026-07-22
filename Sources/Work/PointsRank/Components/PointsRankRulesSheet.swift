import SwiftUI

/// 积分排行榜规则 sheet。对齐 H5 [`views/pointsRank/index.vue`](../../../../../Desktop/HN/anchor-livechat-h5/src/views/pointsRank/index.vue) van-overlay 弹窗
/// —— 4 段规则内容(rank.answer1-4),Confirm 按钮关闭。
struct PointsRankRulesSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.58).ignoresSafeArea()
            VStack(spacing: 20) {
                Text(L10n.pointsRankRulesTitle)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.pointsRankRulesContent1)
                    Text(L10n.pointsRankRulesContent2)
                    Text(L10n.pointsRankRulesContent3)
                    Text(L10n.pointsRankRulesContent4)
                }
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.7))
                .lineSpacing(4)
                Button(action: onDismiss) {
                    Text(L10n.commonOK)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            LinearGradient(colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .frame(maxWidth: 334)
            .background(Color(hex: 0x5300A1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 20)
        }
        .preferredColorScheme(.dark)
    }
}
