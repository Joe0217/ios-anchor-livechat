import SwiftUI

/// PK 贡献榜 sheet（对齐 H5 pkRankListPopup.vue）。
///
/// 视觉：
/// - **顶部 header**：side 色调（my=粉紫；opponent=蓝紫）+ 当前 side 主播头像 + "Guardian Fans List" 标题
/// - **列表 row**：rank icon(top3) / 数字(4+) + 头像 + nickname + optional level/VIP + optional country + contribution 值
/// - **loading / empty / error** 三态与 ContributionSheetView 保持一致视觉
///
/// 交互：`.presentationDetents([.medium, .large])` 系统下拉手势关闭，无自定义关闭按钮（对齐 ContributionSheetView v20）。
struct PKRankSheetView: View {
    @StateObject private var store: PKRankStore
    let side: PKRankSide
    let anchorAvatarURL: String?
    let anchorNickname: String

    init(side: PKRankSide,
         pkId: String,
         anchorId: Int,
         anchorAvatarURL: String?,
         anchorNickname: String) {
        self._store = StateObject(wrappedValue: PKRankStore(pkId: pkId, anchorId: anchorId))
        self.side = side
        self.anchorAvatarURL = anchorAvatarURL
        self.anchorNickname = anchorNickname
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Color(hex: 0x17053D).ignoresSafeArea())
        .onAppear(perform: store.onAppear)
    }

    // MARK: - Header

    /// header 背景色按 side 分色（对齐 H5 `rank-top-header` vs `rank-top-header-opponent`）
    private var headerBackground: LinearGradient {
        switch side {
        case .my:
            return LinearGradient(colors: [Color(hex: 0xF8179D, opacity: 0.35),
                                           Color(hex: 0x17053D, opacity: 0)],
                                  startPoint: .top, endPoint: .bottom)
        case .opponent:
            return LinearGradient(colors: [Color(hex: 0x1068FA, opacity: 0.35),
                                           Color(hex: 0x17053D, opacity: 0)],
                                  startPoint: .top, endPoint: .bottom)
        }
    }

    /// 头像描边色（my=粉；opponent=蓝）
    private var headerAvatarBorder: Color {
        switch side {
        case .my:       return Color(hex: 0xFF9DEA)
        case .opponent: return Color(hex: 0x9DC6FF)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AvatarView(urlString: anchorAvatarURL, size: 24, kind: .anchor)
                .overlay(Circle().stroke(headerAvatarBorder, lineWidth: 1))

            Text(L10n.PK.rankSheetTitle)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(headerBackground)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(L10n.PK.rankSheetTitle) - \(anchorNickname)"))
    }

    // MARK: - Content 三态

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading:
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let items):
            if items.isEmpty {
                emptyState
            } else {
                rankList(items)
            }
        case .error:
            errorState
        }
    }

    private func rankList(_ items: [PKRankItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    PKRankRow(item: item, rank: idx + 1)
                    Divider().background(Color.white.opacity(0.06))
                }
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorState: some View {
        VStack(spacing: 12) {
            Text(L10n.liveRoomContributionErrorRetry)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
            Button(action: store.retry) {
                Text(L10n.liveRoomRetry)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24).padding(.vertical, 8)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// PK 贡献榜单条 row（对齐 H5 pkRankListPopup.vue L124-203）。
private struct PKRankRow: View {
    let item: PKRankItem
    let rank: Int

    var body: some View {
        HStack(spacing: 12) {
            rankBadge
            AvatarView(urlString: item.avatar, size: 44, kind: .user)
            infoColumn
            Spacer(minLength: 8)
            contributionValue
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// 排名徽章（Top1-3 用切图，4+ 用数字）
    @ViewBuilder
    private var rankBadge: some View {
        switch rank {
        case 1:
            Image("pkBattleMVP").resizable().frame(width: 24, height: 24)
        case 2:
            Image("pkBattleRank2").resizable().frame(width: 24, height: 24)
        case 3:
            Image("pkBattleRank3").resizable().frame(width: 24, height: 24)
        default:
            Text("\(rank)")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Color(hex: 0xFFE600))
                .frame(width: 24, alignment: .center)
        }
    }

    /// 中间信息列（nickname + level + VIP + optional country chip）
    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.nickName ?? L10n.anonymous)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)

                // 等级徽章：走公共 UserLevelBadge（levelName nil/空/非数字自动不渲染）
                UserLevelBadge(levelName: item.levelName, size: .small)

                if item.isVip {
                    Image("liveListVipBadge")
                        .resizable()
                        .frame(width: 31, height: 14)
                        .accessibilityLabel(Text("VIP"))
                }
            }

            if let country = item.countryId, !country.isEmpty {
                countryChip(country)
            }
        }
    }

    private func countryChip(_ country: String) -> some View {
        HStack(spacing: 2) {
            Image("liveListLocation")
                .resizable()
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(country)
                .font(.system(size: 12))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
    }

    /// 贡献值（右侧粉色 #FD00DD 高亮，对齐 H5 L198）
    private var contributionValue: some View {
        VStack(alignment: .trailing, spacing: 4) {
            // TODO 素材：H5 用 `livePk/pk-history-icon.webp`（金/紫奖章），iOS 暂用 `livePkIcon` 兜底
            // 待设计出对应切图后替换（PK 语义 vs 钻石语义 已修正）
            Image("livePkIcon")
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(formatContribution(item.contribution))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color(hex: 0xFD00DD))
        }
    }

    /// 万级简写（>=10000 → x.xw）
    private func formatContribution(_ n: Int) -> String {
        if n >= 10_000 { return String(format: "%.1fw", Double(n) / 10_000.0) }
        return "\(n)"
    }
}
