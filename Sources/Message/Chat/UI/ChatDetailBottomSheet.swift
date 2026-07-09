import SwiftUI

/// 私聊页半屏拓展点（H-2 spec §0.3 拓展 · 直播间 / 派对房内嵌半屏聊天）。
///
/// **用法**（1 行接入）：
/// ```swift
/// LiveRoomView(...)
///     .chatDetailBottomSheet(peer: $chatPeer, selfYxAccId: session.selfYxAccId)
/// ```
///
/// **触发**：将 `chatPeer` 从 nil 置为 `yxAccId` 即弹半屏；置 nil 关闭。例如：
/// ```swift
/// Button("Chat") { chatPeer = "someYxAccId" }
/// ```
///
/// **架构**：
/// - `.sheet(item:)` 保证同一时刻只弹一个（`swiftui-fullscreencover-hoist.md` 规则 1
///   要求 modal modifier hoist 到单一容器 —— 本 modifier **必须由调用方挂到 view 顶层**，
///   不能挂到 ForEach / 各消息列表 row 上）
/// - `presentationDetents([.medium, .large])` 支持半屏拖到全屏
/// - 半屏模式内 `ChatDetailView` 顶部左侧图标从 back(chevron.left) 切换为 close(xmark)
///
/// **与全屏 push 差异**：
/// - Messages tab → 私聊页：`NavigationStack.push` 全屏（隐藏 tabbar），`onClose = nil`
/// - LiveRoom / PartyRoom → 私聊页：`.sheet(medium)` 半屏，`onClose = { peer = nil }`
struct ChatDetailBottomSheet: ViewModifier {
    @Binding var peerYxAccId: String?
    let selfYxAccId: String

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { peerYxAccId.map { PeerIdentifier(id: $0) } },
                set: { peerYxAccId = $0?.id }
            )) { peer in
                sheetContent(peer: peer.id)
            }
    }

    @ViewBuilder
    private func sheetContent(peer: String) -> some View {
        // 半屏 sheet 内不套 NavigationStack（避免嵌套 NavigationStack 引起手势冲突）；
        // ChatDetailView 顶部自带 nav 条，close 按钮由 onClose 触发
        ChatDetailContainer(
            peerYxAccId: peer,
            selfYxAccId: selfYxAccId,
            onClose: { peerYxAccId = nil }
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(false)
    }
}

/// URL / String 不是 Identifiable，包一层给 `.sheet(item:)` 用
private struct PeerIdentifier: Identifiable, Equatable {
    let id: String
}

// MARK: - View 扩展 · 1 行接入

extension View {

    /// 挂载私聊页半屏 sheet（H-2 拓展点）。
    ///
    /// - 由 LiveRoomView / PartyRoomView 顶层调用一次
    /// - 触发方式：设 `peer.wrappedValue = "yxAccId"` 弹起；nil 关闭
    ///
    /// - Parameters:
    ///   - peer: 对端 yxAccId 的 optional binding（nil = 关；非 nil = 展示）
    ///   - selfYxAccId: 我方 yxAccId（从 SessionStore.shared.user?.yxAccid 取）
    func chatDetailBottomSheet(peer: Binding<String?>, selfYxAccId: String) -> some View {
        modifier(ChatDetailBottomSheet(peerYxAccId: peer, selfYxAccId: selfYxAccId))
    }
}
