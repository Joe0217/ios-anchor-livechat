import SwiftUI

/// v9 4 新 sheet/popup 挂载 ViewModifier —— 缓解 LiveRoomView.body SwiftUI type-check timeout
/// 挂：虚拟道具开关 popup / 公告管理 popup / UserCard popup / GiftPicker sheet
struct LiveRoomExtraOverlaysModifier: ViewModifier {
    @ObservedObject var virtualPropsStore: VirtualPropsStore
    @Binding var showEffectSwitchPopup: Bool
    @Binding var showAnnouncementPopup: Bool
    @Binding var userCardUserId: String?
    @Binding var showGiftPicker: Bool
    let roomIdStr: String
    /// v10 心愿单 store + 面板 binding + liveRecordId（Top6 API 用）
    @ObservedObject var wishlistStore: WishlistStore
    @Binding var showWishlistPanel: Bool
    let liveRecordId: String
    /// v20 公告保存成功回调 —— 父层用于往公屏 messagesStore append announcement 消息
    let onAnnouncementSaved: (String) -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                VirtualPropsEffectSwitchPopup(isPresented: $showEffectSwitchPopup,
                                              store: virtualPropsStore)
            }
            .overlay {
                AnnouncementPopup(roomId: roomIdStr,
                                  isPresented: $showAnnouncementPopup,
                                  onSaved: onAnnouncementSaved)
            }
            // UserCard 名片卡:sheet 挂载(H5 主播端 userCard.vue 对齐,底部 sheet 形态)
            // 主播端直播间 tap 头像不跳 UserProfile(对齐 H5 `route.path === '/liveSetting'` 分支)
            // Message 按钮暂未接聊天页(D 里程碑 chat push 就绪后再传 callback)
            .userCardSheet(
                item: Binding(
                    get: { userCardUserId.map { UserCardPresentation(userId: $0) } },
                    set: { userCardUserId = $0?.userId }
                )
            )
            .sheet(isPresented: $showGiftPicker) {
                // H-4 迁移：直播中礼物入口 = 纯展示（interaction=.readonly + footer=.none）
                CommonGiftPanel(config: .liveDisplayOnly)
                    .sheetTopInset()
                    .presentationDetents([.fraction(0.4)])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showWishlistPanel) {
                WishlistAnchorPanel(store: wishlistStore,
                                    isPresented: $showWishlistPanel,
                                    liveRecordId: liveRecordId,
                                    onGifterTap: { userCardUserId = $0 })
                    .sheetTopInset()
                    .giftPanelSheetBackground()
                    .presentationDetents([.fraction(0.4)])
                    .presentationDragIndicator(.visible)
            }
    }

}
