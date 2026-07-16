import SwiftUI

/// 礼物 4 列 grid（spec §3.1，对齐设计稿 `送礼弹窗-背包礼物.png`）。
///
/// - 4 列 LazyVGrid（旧 3 列 → 4 列全局统一，用户已签视觉密度变化）
/// - cell tap：selectable → 切换选中；instantSelect → 立即触发（Store.triggerInstantSelect）；readonly → no-op
/// - cell 选中高亮：pink border + 淡 pink 底色（interaction=readonly 时永远不高亮）
///
/// **v2（2026-07-09）**：新增 `tab` 参数 —— 多 tab 场景下 TabView(.page) 每 page 独立渲染
/// 对应 tab 的 gifts（对齐 H5 newGiftsPopup v-swiper 支持横滑切 tab）。
struct GiftPanelGrid: View {
    @ObservedObject var store: CommonGiftPanelStore
    let tab: GiftPanelTab

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(store.gifts(for: tab)) { gift in
                    cell(gift)
                }
            }
            // 内边距压缩：16/12 → 8/6（让礼物 grid 视觉更紧凑）
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func cell(_ gift: GiftListData) -> some View {
        let isSelected = store.config.interaction == .selectable && store.selectedId == gift.id
        // Party 场景（FooterMode.send）用紫色钻石 partyGems；其他场景（callGate/wishGift/liveDisplayOnly/imBind/callAskFor）
        // 沿用黄色 SF Symbol diamond.fill（本地 fallback，未来可视觉统一时集中改）
        let isPartySend: Bool = {
            if case .send = store.config.footer { return true }
            return false
        }()
        return Button(action: { handleTap(gift) }) {
            VStack(spacing: 4) {
                // persistent=true：礼物图片高频复用 + 跨会话持久（NSCache 150MB 内存 + URLCache 磁盘）
                //   ImageCache.shared 已按 URL LRU；礼物图数量有限（几十个）大小小（几十 KB）总占用可控
                CachedAsyncImage(url: URL(string: gift.giftSmallImg.isEmpty ? gift.giftImg : gift.giftSmallImg),
                                 contentMode: .fit,
                                 persistent: true,
                                 cdn: (.gift, .fit)) {
                    Color.white.opacity(0.06)
                }
                .frame(width: 50, height: 50)  // 统一 50x50

                Text(gift.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                    .padding(.horizontal, 4)

                HStack(spacing: 2) {
                    if isPartySend {
                        // Party 房送礼场景：紫钻 partyGems
                        Image("partyGems")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 10, height: 10)
                    } else if store.config.useBlueDiamond {
                        // F-spec 派对房私 call 场景：蓝色钻石（对齐设计稿）
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 9))
                            .foregroundColor(Color(hex: 0x4E9AFF))
                    } else {
                        // 其他场景（wishGift / callGate / liveDisplayOnly / imBind / callAskFor）：coins 金币图标
                        Image("coins")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 10, height: 10)
                    }
                    Text("\(gift.giftPrice)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                // 未选中：无背景色（对齐产品需求·仅选中时用淡粉底 + 边框视觉高亮）
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Theme.Palette.brandPink.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Theme.Palette.brandPink : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy)
    }

    private func handleTap(_ gift: GiftListData) {
        switch store.config.footer {
        case .instantSelect:
            store.triggerInstantSelect(gift)
        default:
            store.selectGift(gift.id)
        }
    }
}
