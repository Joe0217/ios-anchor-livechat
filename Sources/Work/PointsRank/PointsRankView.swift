import SwiftUI

/// Phase E —— 积分排行榜主页。对齐 H5 [`views/pointsRank/index.vue`](../../../../Desktop/HN/anchor-livechat-h5/src/views/pointsRank/index.vue)。
///
/// **布局**:
/// - H5 同款榜单背景位图
/// - Header:MyPoints pill + subtitle 说明
/// - Top3 领奖台(仅有数据时)
/// - RankList(4 名起 LazyVStack)
/// - 规则遮罩弹窗(nav 右上 question 触发)
struct PointsRankView: View {
    @StateObject private var store = PointsRankStore()
    @State private var showRulesSheet = false
    @State private var enteredAt = Date()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerArea

                PointsRankTop(items: store.topThree)
                    .padding(.top, 12)

                // RankList(4 名起)
                rankListArea
                    .padding(.top, 12)
                    .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .background(
            Image("homePointsBackground")
                .resizable()
                .ignoresSafeArea()
        )
        .refreshable { await store.refresh() }
        .navigationTitle(L10n.pointsRankNavTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(hex: 0x613AF4), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showRulesSheet = true } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(L10n.pointsRankRulesTitle)
            }
        }
        .overlay {
            if showRulesSheet {
                PointsRankRulesSheet { showRulesSheet = false }
            }
        }
        .task {
            HomeRankingAnalytics.report("h_rank_view", properties: ["type": "point", "page": "", "path": "mine"])
            store.onAppear()
        }
        .onDisappear {
            let duration = Int(Date().timeIntervalSince(enteredAt) * 1_000)
            HomeRankingAnalytics.report("h_rank_leave", properties: ["type": "point", "duration": "\(duration)"])
        }
    }

    // MARK: - Header:MyPoints pill + subtitle

    private var headerArea: some View {
        VStack(spacing: 15) {
            HStack(spacing: 6) {
                Text(L10n.pointsMyPoints)
                    .foregroundStyle(.white)
                Text("\(store.myIntegral)")
                    .foregroundStyle(Color(hex: 0xFFE600))
            }
            .font(.system(size: 14))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color(hex: 0x200032).opacity(0.36))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 10)

            Text(L10n.pointsRankSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - RankList(4 名起)

    private var rankListArea: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(store.restList.enumerated()), id: \.element.userId) { i, item in
                PointsRankRow(item: item, ranking: i + 4)
                if i < store.restList.count - 1 {
                    Divider().background(Color.white.opacity(0.05))
                        .padding(.horizontal, 20)
                }
            }
        }
        .background(Color(hex: 0x2B213E))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 0)
    }

}
