import SwiftUI

/// LiveGiftTaskSheet 挂载 ViewModifier —— 独立于 TopSheetsModifier 避免 body type-check 超时
/// (spec §3.1 v2 决策,对齐 [swiftui-body-type-check-timeout](.claude/rules/swiftui-body-type-check-timeout.md))。
///
/// **使用**:LiveRoomView bodyStage1 内 TopSheetsModifier 相邻:
/// ```swift
/// .modifier(LiveGiftTaskSheetModifier(
///     isPresented: $showTaskSheet,
///     store: nim.liveGiftTaskStore,
///     anchorId: "\(SessionStore.shared.user?.userId ?? 0)",
///     onUserTap: { uid in userCardUserId = uid }
/// ))
/// ```
///
/// H5 面板固定高度为 460；任务历史本身有独立滚动区，因此使用相同高度而非让系统
/// 按屏幕比例压缩内容。
struct LiveGiftTaskSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let store: LiveGiftTaskStore
    let anchorId: String
    let onUserTap: (String) -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            LiveGiftTaskSheet(
                store: store,
                anchorId: anchorId,
                isPresented: $isPresented,
                onUserTap: { userId in
                    guard !userId.isEmpty else { return }
                    isPresented = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        onUserTap(userId)
                    }
                }
            )
            .sheetTopInset()
            .presentationDetents([.height(460)])
            .presentationDragIndicator(.visible)
        }
    }
}
