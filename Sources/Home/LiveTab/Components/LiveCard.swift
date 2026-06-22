import SwiftUI

/// 单张直播卡片：
/// - 占位渐变背景（无真实主播自拍素材，用 Theme 配色块占位）
/// - 左下小头像 + 主播昵称
/// - 右下「观看人数」橘色文字 + 眼睛图标（无背景胶囊）
/// - （可选）右下角贴 "Live" 徽章 → 替代该卡的观看人数
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
        VStack(spacing: 0) {
            Spacer()
            HStack(alignment: .bottom) {
                anchorTag
                Spacer()
                // 带 Live 徽章的卡片右下角是 Live 标，不再显示观看人数文字
                if !card.showLiveBadge {
                    viewerCountInline
                }
            }
        }
        .padding(8)
    }

    /// 右下角观看人数：橘色文字 + 眼睛图标（无背景胶囊），12pt medium
    private var viewerCountInline: some View {
        HStack(spacing: 3) {
            Image("liveViewerCount")
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(card.viewerCount)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Palette.liveViewerBadge)
        }
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
