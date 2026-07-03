import SwiftUI

/// 首页顶部礼物跑马灯（H5 `views/home/liveList.vue` c-marquee）。
///
/// - 单条：左侧头像 + 昵称（绿色）+ "sends out a super rocket"（白）+ 右侧钻石金额（黄）
/// - 多条：3s 一条自动循环切换（H5 autoplay 3000ms + loop）
/// - 空态：完全不渲染（H5 `v-if="marqueeList.length"`）
///
/// 紫粉横向渐变胶囊底 + 玫红描边——沿用旧 mock 版本的视觉。
struct LiveNoticeBar: View {
    let items: [GiftMarqueeItem]

    @State private var currentIndex: Int = 0

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            singleRow(items[safeIndex])
                .frame(height: Theme.Metric.liveNoticeBarHeight)
                .background(
                    Capsule().fill(Theme.Gradients.liveNoticeBar)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Theme.Palette.liveNoticeBarBorder.opacity(0.6), lineWidth: 1)
                )
                .animation(.easeInOut(duration: 0.35), value: currentIndex)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityText(items[safeIndex]))
                .onAppear { startAutoplay() }
                .onChange(of: items.count) { _ in
                    // items 变更（如刷新后条数变化），重置索引避免越界
                    currentIndex = 0
                }
        }
    }

    /// 归一化索引——items 变更时 currentIndex 可能瞬时越界。
    private var safeIndex: Int {
        guard !items.isEmpty else { return 0 }
        return currentIndex % items.count
    }

    private func singleRow(_ item: GiftMarqueeItem) -> some View {
        HStack(spacing: 8) {
            avatar(item)
            HStack(spacing: 4) {
                Text(item.nickname)
                    .foregroundStyle(Theme.Palette.liveNoticeUserGreen)
                Text(L10n.giftSendSuperRocket)
                    .foregroundStyle(.white)
            }
            .font(Theme.Typography.liveNotice)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            Spacer(minLength: 6)
            amountTag(item.diamond)
        }
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .id(item.id) // 让 SwiftUI 视新 item 为新 view，配合外层 animation 做过渡
        .transition(.opacity)
    }

    private func avatar(_ item: GiftMarqueeItem) -> some View {
        AvatarView(
            urlString: item.icon,
            size: 32,
            kind: .user,
            showsOnlineDot: false
        )
    }

    private func amountTag(_ amount: String) -> some View {
        HStack(spacing: 4) {
            Image("liveMarqueeDiamond")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(amount)
                .font(Theme.Typography.liveNoticeNum)
                .foregroundStyle(Theme.Palette.liveNoticeNumber)
        }
    }

    private func accessibilityText(_ item: GiftMarqueeItem) -> String {
        "\(item.nickname) \(L10n.giftSendSuperRocket) \(item.diamond)"
    }

    /// SwiftUI 无内置 marquee 组件；起 Task 每 3s 切一条。
    /// items 数量变化 / view 消失自动收敛（Task.isCancelled + count guard）。
    private func startAutoplay() {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard items.count > 1 else { return }
                currentIndex = (currentIndex + 1) % items.count
            }
        }
    }
}

#if DEBUG
struct LiveNoticeBar_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            LiveNoticeBar(items: [])
                .previewDisplayName("空态（不渲染）")
            LiveNoticeBar(items: [
                GiftMarqueeItem(id: "1", icon: nil, nickname: "Emma", diamond: "99999"),
            ])
            .previewDisplayName("单条")
            LiveNoticeBar(items: [
                GiftMarqueeItem(id: "1", icon: nil, nickname: "Emma", diamond: "99999"),
                GiftMarqueeItem(id: "2", icon: nil, nickname: "Sarah", diamond: "12345"),
                GiftMarqueeItem(id: "3", icon: nil, nickname: "Alex", diamond: "888"),
            ])
            .previewDisplayName("多条 3s 循环")
        }
        .padding()
        .background(Theme.Palette.liveBottomDark)
        .preferredColorScheme(.dark)
    }
}
#endif
