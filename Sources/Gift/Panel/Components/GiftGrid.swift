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
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(store.gifts(for: tab)) { gift in
                    cell(gift)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func cell(_ gift: GiftListData) -> some View {
        let isSelected = store.config.interaction == .selectable && store.selectedId == gift.id
        return Button(action: { handleTap(gift) }) {
            VStack(spacing: 4) {
                CachedAsyncImage(url: URL(string: gift.giftSmallImg.isEmpty ? gift.giftImg : gift.giftSmallImg),
                                 contentMode: .fit,
                                 persistent: false,
                                 cdn: (.gift, .fit)) {
                    Color.white.opacity(0.06)
                }
                .frame(width: 56, height: 56)

                Text(gift.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                    .padding(.horizontal, 4)

                HStack(spacing: 2) {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.yellow)
                    Text("\(gift.giftPrice)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.pink.opacity(0.18) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.pink : Color.clear, lineWidth: 1.5)
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
