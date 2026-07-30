import SwiftUI

/// v9 4 新 sheet/popup 挂载 ViewModifier —— 缓解 LiveRoomView.body SwiftUI type-check timeout
/// 挂：虚拟道具开关 popup / 公告管理 popup / UserCard popup / GiftPicker sheet
struct LiveRoomExtraOverlaysModifier: ViewModifier {
    @ObservedObject var virtualPropsStore: VirtualPropsStore
    @Binding var showEffectSwitchPopup: Bool
    @Binding var showAnnouncementPopup: Bool
    @Binding var userCardUserId: String?
    /// 名片卡 Message → 半屏私聊。由 LiveRoomView 顶层唯一的 chatDetailBottomSheet 承载。
    @Binding var chatSheetPeerYxAccid: String?
    @Binding var showGiftPicker: Bool
    let roomIdStr: String
    /// v10 心愿单 store + 面板 binding + liveRecordId（Top6 API 用）
    @ObservedObject var wishlistStore: WishlistStore
    @Binding var showWishlistPanel: Bool
    let liveRecordId: String
    /// v20 公告保存成功回调 —— 父层用于往公屏 messagesStore append announcement 消息
    let onAnnouncementSaved: (String) -> Void
    @State private var pendingUserCardUserId: String?

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
            // H5 userCard 的 Message → openTalkPopup(yxAccid)：原生由房间顶层半屏私聊承载。
            .userCardSheet(
                item: Binding(
                    get: { userCardUserId.map { UserCardPresentation(userId: $0) } },
                    set: { userCardUserId = $0?.userId }
                ),
                onMessageTap: { _, yxAccid in
                    guard let yxAccid, !yxAccid.isEmpty else { return }
                    // 对齐 H5 useMessageHooks.openTalkPopup：先关闭名片卡，再展示 TalkPopup。
                    userCardUserId = nil
                    DispatchQueue.main.async {
                        chatSheetPeerYxAccid = yxAccid
                    }
                }
            )
            .sheet(isPresented: $showGiftPicker) {
                // H-4 迁移：直播中礼物入口 = 纯展示（interaction=.readonly + footer=.none）
                CommonGiftPanel(config: .liveDisplayOnly)
                    .sheetTopInset()
                    .presentationDetents([.fraction(0.4)])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showWishlistPanel, onDismiss: presentPendingUserCardAfterWishlistDismissal) {
                WishlistAnchorPanel(store: wishlistStore,
                                    isPresented: $showWishlistPanel,
                                    liveRecordId: liveRecordId,
                                    onGifterTap: { userId in
                                        guard shouldPresentUserCard(for: userId) else { return }
                                        pendingUserCardUserId = userId
                                        showWishlistPanel = false
                                    })
                    .sheetTopInset()
                    .giftPanelSheetBackground()
                    .presentationDetents([.fraction(0.4)])
                    .presentationDragIndicator(.visible)
            }
    }

    private func presentPendingUserCardAfterWishlistDismissal() {
        guard let userId = pendingUserCardUserId else { return }
        pendingUserCardUserId = nil
        userCardUserId = userId
    }

    private func shouldPresentUserCard(for userId: String) -> Bool {
        guard !userId.isEmpty else { return false }
        return userId != String(SessionStore.shared.user?.userId ?? 0)
    }

}
