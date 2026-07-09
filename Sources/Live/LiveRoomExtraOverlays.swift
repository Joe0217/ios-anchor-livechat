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
            .overlay {
                userCardOverlay
            }
            .sheet(isPresented: $showGiftPicker) {
                // H-4 迁移：直播中礼物入口 = 纯展示（interaction=.readonly + footer=.none）
                CommonGiftPanel(config: .liveDisplayOnly)
                    .sheetTopInset()
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showWishlistPanel) {
                WishlistAnchorPanel(store: wishlistStore,
                                    isPresented: $showWishlistPanel,
                                    liveRecordId: liveRecordId)
                    .sheetTopInset()
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
    }

    /// UserCard 挂载：nil = 不显示；非 nil = 显示对应 userId 的 popup
    @ViewBuilder
    private var userCardOverlay: some View {
        if let uid = userCardUserId {
            UserCardPopup(userId: uid,
                          isPresented: Binding(
                            get: { userCardUserId != nil },
                            set: { if !$0 { userCardUserId = nil } }
                          ))
        }
    }
}
