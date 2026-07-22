import SwiftUI

/// 广场单张直播卡片：
/// - 背景：`backgroundImgUrl` 封面图（走 CachedAsyncImage）；nil/失败走 Theme 占位渐变
/// - 右上：`weekIncome` 胶囊（有值才显示；对齐 H5 rgba(211,57,1,0.6) 底色 + 黄钻石图标）
/// - 左上：`diamondGiftActive === 1` 钻石盲盒 22×22 角标
/// - 左下：头像圆 + 昵称（black shadow 增强白字对比）
/// - 右下：PK 中 → PK 角标；否则观看数橘字（H5 #FA7800）
struct LiveStreamCard: View {
    let anchor: LiveStreamAnchor

    var body: some View {
        // 用 Rectangle 做 sizing anchor：aspectRatio 加在 ZStack 上时若子 view 带 intrinsic size
        // （Image.resizable() 后仍保留 image dimensions 做 preferred size），ZStack 会被撑爆。
        // Rectangle 是 flexible + 无 intrinsic size，配 aspectRatio(.fit) 能稳定占父容器宽 × 4/3 高。
        // coverBackground / overlayContent 走 overlay 附着，永远 match Rectangle 的 3:4 尺寸。
        Rectangle()
            .fill(Color.clear)
            .aspectRatio(Theme.Metric.liveCardWidthOverHeight, contentMode: .fit)
            .overlay(coverBackground)
            .overlay(overlayContent)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.liveCard, style: .continuous))
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
    }

    /// 背景层：封面图（走 ImageCache 持久缓存，避免滚回来重新加载）+ 顶部渐变蒙层增强角标可读性。
    /// Image.resizable + aspectRatio(.fill) 会向 host 中心溢出，加 `.clipped()` 拦掉溢出。
    private var coverBackground: some View {
        ZStack {
            CachedAsyncImage(url: anchor.backgroundImgURL, contentMode: .fill, persistent: true, cdn: (.custom(width: 800), .fill)) {
                placeholderGradient
            }
            // 底部渐变蒙层：H5 `list-grid-item` 同款 linear-gradient(rgba(0,0,0,0)→rgba(0,0,0,0.3))
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.35)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .clipped()
    }

    /// 无封面时的占位渐变——沿用 mock 时 Sarah 卡片的紫粉调色，保持视觉不突兀。
    private var placeholderGradient: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0xC79988), Color(hex: 0x5E3D4D)],
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
        ZStack(alignment: .topLeading) {
            // 上排：左钻石盲盒 / 右周收入
            HStack {
                if anchor.hasDiamondGift {
                    Image("coins")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 4)
                if let income = anchor.weekIncome {
                    weekIncomeChip(income)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .top)

            // 下排：左头像+昵称 / 右 PK 角标 或 观看数
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    anchorTag
                    Spacer()
                    if anchor.isInPK {
                        pkBadge
                    } else {
                        viewerCountInline
                    }
                }
            }
            .padding(8)
        }
    }

    private func weekIncomeChip(_ income: String) -> some View {
        HStack(spacing: 2) {
            Image("coins")
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(income)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color(red: 211/255, green: 57/255, blue: 1/255, opacity: 0.6))
        )
    }

    private var pkBadge: some View {
        Image("livePkIcon")
            .resizable()
            .scaledToFit()
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }

    private var viewerCountInline: some View {
        HStack(spacing: 3) {
            Image("liveViewerCount")
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(anchor.joinNum)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: 0xFA7800))
        }
    }

    private var anchorTag: some View {
        HStack(spacing: 6) {
            AvatarView(
                urlString: anchor.icon,
                size: 24,
                kind: .user,
                showsOnlineDot: false
            )
            Text(anchor.nickname)
                .font(Theme.Typography.liveCardName)
                .foregroundStyle(Theme.Palette.liveCardName)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
        }
    }

    private var accessibilityText: String {
        var parts = [anchor.nickname]
        if anchor.isInPK { parts.append(L10n.liveStreamInPK) }
        else { parts.append("\(anchor.joinNum) \(L10n.liveViewers)") }
        if let income = anchor.weekIncome { parts.append(income) }
        return parts.joined(separator: ", ")
    }
}

#if DEBUG
struct LiveStreamCard_Previews: PreviewProvider {
    static var previews: some View {
        let cards: [LiveStreamAnchor] = [
            LiveStreamAnchor(userId: "1", nickname: "Sarah", icon: nil,
                             backgroundImgUrl: nil, joinNum: "2.8k",
                             weekIncome: "12k", pkStatus: nil, diamondGiftActive: 1),
            LiveStreamAnchor(userId: "2", nickname: "Emma", icon: nil,
                             backgroundImgUrl: nil, joinNum: "500",
                             weekIncome: nil, pkStatus: 7, diamondGiftActive: nil),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                        spacing: 8) {
            ForEach(cards) { LiveStreamCard(anchor: $0) }
        }
        .padding()
        .background(Theme.Palette.liveBottomDark)
        .preferredColorScheme(.dark)
    }
}
#endif
