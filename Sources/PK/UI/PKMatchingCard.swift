import SwiftUI

/// PK 随机匹配 embed 卡（对齐 H5 `pkMatchingCard.vue`）。
///
/// **3 态视觉**（iOS 简化，H5 4 态里 quick_matching/further_matching 合并为一个 matching 态）：
/// - `.idle`：主播头像 + PK icon + 对手 ? 占位 + Random PK 按钮
/// - `.matching`：Progress ring 旋转 + "Searching for an opponent" + Cancel 按钮
/// - `.matched`：本端 + 对手双头像 + "Opponent matched successfully"（<500ms 过渡视觉，sheet 会被 handlePKStateChange 关掉）
///
/// **状态源**：`store.state`
/// - `.idle / .failed` → `.idle` 卡片
/// - `.matching` → `.matching` 卡片
/// - `.starting / .inPK / .punishing` → `.matched` 卡片
/// - `.inviting / .invited / .endingPK` → 隐藏（不属于随机匹配路径）
///
/// **交互**：
/// - `.idle` 点 Random PK → onStartMatch callback
/// - `.matching` 点 Cancel → onCancelMatch callback
///
/// **iOS 简化**（不做以下 H5 装饰）：
/// - SVGA 15s 倒计时动画 → 系统 ProgressView + Circle progress ring
/// - PkAvatarCarousel 轮播头像 → 静态默认头像占位
/// - random-pk-card.webp 背景切图 → LinearGradient 紫粉渐变
struct PKMatchingCard: View {
    @ObservedObject var store: PKStore
    let selfAvatarURL: String?
    let onStartMatch: () -> Void
    let onCancelMatch: () -> Void

    private enum Stage {
        case idle       // pkStore.state == .idle / .failed
        case matching   // pkStore.state == .matching
        case matched    // pkStore.state == .starting / .inPK / .punishing
        case hidden     // .inviting / .invited / .endingPK（不属于随机匹配）
    }

    private var stage: Stage {
        switch store.state {
        case .idle, .failed:                   return .idle
        case .matching:                        return .matching
        case .starting, .inPK, .punishing:     return .matched
        case .inviting, .invited, .endingPK:   return .hidden
        }
    }

    var body: some View {
        if stage != .hidden {
            content
                .frame(height: 154)
                .frame(maxWidth: .infinity)
                .background(cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if stage != .matched { statusChip }
                }
                .padding(.bottom, 12)
        }
    }

    // MARK: - Card background（H5 random-pk-card.webp 简化为紫粉渐变）

    private var cardBackground: LinearGradient {
        LinearGradient(colors: [Color(hex: 0x4A1B7A),
                                Color(hex: 0x2C0F52)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - Status chip（左上角，H5 random-pk-card-status 黄金渐变）

    private var statusChip: some View {
        Text(statusChipText)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Color(hex: 0x561A00))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                LinearGradient(colors: [Color(hex: 0xFFF510),
                                        Color(hex: 0xFF8921)],
                               startPoint: .top, endPoint: .bottom)
            )
            .clipShape(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 12,
                                                                  bottomTrailing: 12)))
    }

    private var statusChipText: String {
        switch stage {
        case .idle:     return L10n.PK.entryRandom
        case .matching: return L10n.PK.matchingCardSearching
        default:        return ""
        }
    }

    // MARK: - Content dispatch

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .idle:     idleContent
        case .matching: matchingContent
        case .matched:  matchedContent
        case .hidden:   EmptyView()
        }
    }

    // MARK: - 3 stages content

    /// idle：主播头像 + PK 图标 + 对手 ? 占位 + hint + Random PK 按钮
    private var idleContent: some View {
        VStack(spacing: 4) {
            HStack(spacing: 16) {
                selfAvatar
                pkCenterIcon
                opponentPlaceholder
            }
            .padding(.top, 12)

            Text(L10n.PK.matchingCardHint)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 4)

            Button(action: onStartMatch) {
                Text(L10n.PK.entryRandom)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(hex: 0x561A00))
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(
                        LinearGradient(colors: [Color(hex: 0xFFF400),
                                                Color(hex: 0xFF9421)],
                                       startPoint: .top, endPoint: .bottom),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
    }

    /// matching：Progress ring + "Searching..." + Cancel
    private var matchingContent: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                cancelChip
            }
            .padding(.top, 6).padding(.trailing, 12)

            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.4)
                .padding(.top, 8)

            Text(L10n.PK.matchingSubtitle)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .padding(.top, 12)
        }
    }

    /// matched：双头像 + "Opponent matched successfully"
    private var matchedContent: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                selfAvatar
                pkCenterIcon
                AvatarView(urlString: store.ctx?.oppositeAvatar,
                           size: 44, kind: .anchor)
                    .overlay(Circle().stroke(Color(hex: 0xFF9DEA), lineWidth: 2))
            }
            .padding(.top, 28)

            Text(L10n.PK.matchingCardMatched)
                .font(.system(size: 13))
                .foregroundColor(.white)
        }
    }

    // MARK: - Reusable pieces

    private var selfAvatar: some View {
        AvatarView(urlString: selfAvatarURL, size: 44, kind: .anchor)
            .overlay(Circle().stroke(Color(hex: 0xFF9DEA), lineWidth: 2))
    }

    /// PK center icon（H5 pk-card-icon.webp 简化 —— iOS 无此切图，用 SF Symbol + 金橙色兜底）
    private var pkCenterIcon: some View {
        Image("livePkIcon")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 60, height: 60)
    }

    /// 对手 ? 占位（H5 PkAvatarCarousel 轮播头像简化）
    private var opponentPlaceholder: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 44, height: 44)
            Text("?")
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(.white.opacity(0.7))
        }
        .overlay(Circle().stroke(Color(hex: 0xFF9DEA).opacity(0.5), lineWidth: 2))
    }

    /// 右上角 cancel 胶囊（H5 gradient 粉紫）
    private var cancelChip: some View {
        Button(action: onCancelMatch) {
            Text(L10n.PK.matchingCancel)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(
                    LinearGradient(colors: [Color(hex: 0xFF9438),
                                            Color(hex: 0xFF0090),
                                            Color(hex: 0xFE00DE)],
                                   startPoint: .leading, endPoint: .trailing),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}
