import SwiftUI

/// 心愿单半屏面板（对齐 H5 wishlist-anchor-panel.vue）
///
/// 结构（自上而下）：
/// - 标题：`<主播昵称> 's wish list for this round`
/// - 副标题
/// - 礼物卡 3 列 grid
/// - Top6 贡献者头像榜（30s 轮询）
struct WishlistAnchorPanel: View {
    @ObservedObject var store: WishlistStore
    @Binding var isPresented: Bool
    let liveRecordId: String
    let onGifterTap: (String) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 16) {
                    if store.items.isEmpty {
                        Text(L10n.wishlistPanelEmpty)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.vertical, 28)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(store.items) { item in
                                WishGiftCell(item: item)
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    WishTop6Row(gifters: store.topSixSlots) { gifter in
                        guard let userId = gifter.userId, !userId.isEmpty else { return }
                        // 调用方负责在 sheet 完成关闭后展示根层名片卡。
                        onGifterTap(userId)
                    }
                        .padding(.horizontal, 16).padding(.bottom, 16)
                }
                .padding(.top, 12)
            }
        }
        .onAppear { store.onPanelAppear(liveRecordId: liveRecordId) }
        .onDisappear { store.onPanelDisappear() }
    }

    /// v2 修订（2026-07-09）：删顶部右 X 关闭按钮 —— 用户反馈"sheet 顶部关闭按钮误触"。
    /// 关闭走 sheet drag indicator + swipe down 手势（LiveRoomExtraOverlays sheet 挂载已 `.presentationDragIndicator(.visible)`）。
    private var header: some View {
        VStack(spacing: 4) {
            Text(String(format: L10n.wishlistPanelTitle, store.anchorNickname))
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            Text(L10n.wishlistPanelSubtitle)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
                .padding(.horizontal, 24).padding(.bottom, 8)
        }
        .padding(.top, 8)
    }
}
