import SwiftUI

/// 首页顶部礼物跑马灯（H5 `views/home/liveList.vue` c-marquee）。
///
/// - 单条：左侧头像 + 昵称（绿色）+ "sends out a super rocket"（白）+ 右侧钻石金额（黄）
/// - 多条：3s 一条自动循环切换（H5 autoplay 3000ms + loop）
/// - 空态：完全不渲染（H5 `v-if="marqueeList.length"`）
///
/// H5 固定规格：351×40、12pt 圆角、20pt 头像、红→紫底图和粉红描边。
struct LiveNoticeBar: View {
    let items: [GiftMarqueeItem]
    /// 是否处于可见/活跃状态。keep-alive 架构下 view 不 dismount，autoplay `.task`
    /// 也不会随切走 tab 而 cancel——此参数让父容器（LiveTabView）传"真可见"信号：
    /// `isHomeTabActive && current == .live`；不 active 时 task 立即 return，能耗归零。
    var isActive: Bool = true

    @State private var currentIndex: Int = 0

    /// task id 组合 items.count + isActive——任一变化都 cancel 旧 task 起新 task。
    /// active 切换时 currentIndex **不重置**，切走再回来从当前位置继续；items.count 变化
    /// 时同理，靠 safeIndex `currentIndex % items.count` 兜底越界（不再手动归零）。
    private struct LoopKey: Hashable {
        let count: Int
        let active: Bool
    }

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            // 垂直 slide 转场对齐 H5 `c-marquee`（Swiper vertical + autoplay 3000）。
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(hex: 0xE40132), Color(hex: 0x6021BD)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                singleRow(items[safeIndex])
                    .padding(.horizontal, 12)
            }
            .frame(height: 40)
            .frame(maxWidth: 351)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color(hex: 0xFF0026), Color(hex: 0xFF0088)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 1
                    )
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText(items[safeIndex]))
            // 用 withAnimation 显式包裹 currentIndex 修改触发 singleRow 的 .transition(.asymmetric)
            // ——不用外层 `.animation(_:value: currentIndex)` 隐式动画：后者会 monitor currentIndex
            // 变化给整个 modifier chain 加 transaction，与 `.task(id:)` 的 restart 检测存在干扰
            // （实测切走 tab 后返回时 task 不重启，但 Banner 用 withAnimation 结构则正常）。
            .task(id: LoopKey(count: items.count, active: isActive)) {
                guard isActive, items.count > 1 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if Task.isCancelled { break }
                    withAnimation(.easeInOut(duration: 0.4)) {
                        currentIndex = (currentIndex + 1) % max(items.count, 1)
                    }
                }
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
            .font(.system(size: 12))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            Spacer(minLength: 6)
            amountTag(item.diamond)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 用 currentIndex 而非 item.id 做 view identity：跑马灯后端会返"同一 userId 上榜多次"
        // （送礼数量不同但用户相同），item.id 会重复→SwiftUI 视为同 view→content 更新但无 transition,
        // 视觉上只有 diamond 数字变、头像/昵称/整卡片不动，用户误以为"跑马灯没切换"。
        // currentIndex 单调递增永不重复，保证每次切换都触发 slide transition。
        .id(currentIndex)
        // 垂直 slide：新条从底部滑入 + 淡入；旧条向顶部滑出 + 淡出（对齐 H5 c-marquee 竖向 Swiper）
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        ))
    }

    private func avatar(_ item: GiftMarqueeItem) -> some View {
        AvatarView(
            urlString: item.icon,
            size: 20,
            kind: .user,
            showsOnlineDot: false
        )
    }

    private func amountTag(_ amount: String) -> some View {
        HStack(spacing: 4) {
            Image("coins")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(amount)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0xFFE600))
        }
    }

    private func accessibilityText(_ item: GiftMarqueeItem) -> String {
        "\(item.nickname) \(L10n.giftSendSuperRocket) \(item.diamond)"
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
