import SwiftUI

/// 单张直播卡片：
/// - 占位渐变背景（无真实主播自拍素材，用 Theme 配色块占位）
/// - 左下小头像 + 主播昵称
/// - 右上「观看人数」徽章
/// - （可选）右下 "Live" 徽章
struct LiveCard: View {
    let card: LiveAnchorCard

    var body: some View {
        ZStack {
            placeholderBackground
            overlayContent
        }
        .aspectRatio(Theme.Metric.liveCardWidthOverHeight, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.liveCard, style: .continuous))
        // Live 徽章贴在卡片外角，放 clipShape 之后避免被裁
        .overlay(alignment: .bottomTrailing) {
            if card.showLiveBadge {
                Image("liveBadge")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .offset(x: 6, y: 6)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.name), \(card.viewerCount) \(L10n.liveViewers)")
    }

    /// 占位背景：双色渐变 + 系统 person 剪影（替代真实主播自拍）
    private var placeholderBackground: some View {
        ZStack {
            LinearGradient(
                colors: [card.placeholderTop, card.placeholderBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            Image(systemName: "person.fill")
                .font(.system(size: 100, weight: .regular))
                .foregroundStyle(.white.opacity(0.12))
                .offset(y: 10)
        }
    }

    private var overlayContent: some View {
        VStack {
            HStack {
                Spacer()
                viewerBadge
            }
            Spacer()
            HStack(alignment: .bottom) {
                anchorTag
                Spacer()
            }
        }
        .padding(8)
    }

    /// 右上观看人数徽章：橙红渐变胶囊 + 眼睛切图 + 数字
    private var viewerBadge: some View {
        HStack(spacing: 4) {
            Image("liveViewerCount")
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
            Text(card.viewerCount)
                .font(Theme.Typography.liveViewerBadge)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.liveViewerBadge, style: .continuous)
                .fill(Theme.Gradients.liveViewerBadge)
        )
    }

    /// 左下小头像 + 昵称
    private var anchorTag: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0xE9C9A2), Color(hex: 0x6E4E32)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
            Text(card.name)
                .font(Theme.Typography.liveCardName)
                .foregroundStyle(Theme.Palette.liveCardName)
                .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
        }
    }
}
