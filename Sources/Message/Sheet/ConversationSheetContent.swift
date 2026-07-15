import SwiftUI

/// 半屏消息列表（直播间 / 派对房拉起）——对齐 H5 `views/liveSetting/components/messagePopup.vue`。
///
/// **与主消息 tab 差异**：
/// - **无 tab 分类**（H5 平铺）—— 3 类 flame / prime / stranger 并集去重
/// - **无长按操作**（H5 sheet 场景不做置顶/删除，保持轻量）
/// - **无系统消息入口**（H5 里 messagePopup 已 filter 掉 notification/customer/admin，与 MessageSessionStore.sessions(in:) 排除逻辑一致）
/// - **无 header 关闭按钮**（sheet 系统下拉手势 + drag indicator 已足够关闭）
///
/// **数据源**：直接复用 `MessageSessionStore.shared`（会话列表已由 SessionStore login/logout 双入口刷新），
/// 不新增 provider / API。
///
/// **架构**：半屏私聊 sheet 挂在本 view 内部（sheet-over-sheet），
/// 而非 LiveRoomView 顶层——SwiftUI 同一 view 挂多个平行 sheet 时同一时刻只允许一个显示，
/// 会出现"点会话 → 消息列表关闭后才显示私聊"的错觉。挂内层可正常叠加。
struct ConversationSheetContent: View {

    @ObservedObject var store: MessageSessionStore
    /// ChatDetailContainer 构造用 —— 由 LiveRoomView / PartyRoomView 从 SessionStore 传入
    let selfYxAccId: String
    /// 关闭整个消息列表 sheet（点会话进私聊时不调，仅供未来扩展用）
    let onClose: () -> Void

    /// 内部挂的半屏私聊 sheet 承载 —— nil 时不显示；非 nil 触发 sheet(item:) 弹出
    @State private var selectedChatPeer: ChatSheetPeer? = nil
    /// 半屏私聊 sheet 的 detent selection —— 键盘弹起时 ChatDetailView 通过 sheetDetent binding 主动切 `.large`
    /// 避免与键盘上升动画曲线冲突造成卡顿
    @State private var chatSheetDetent: PresentationDetent = .medium

    /// flame ∪ prime ∪ stranger 并集去重 —— 覆盖所有对齐 H5 平铺显示的常规 P2P 会话。
    /// MessageSessionStore.sessions(in:) 已排除 system/notification/admin/customer 系统会话。
    private var allSessions: [MessageSession] {
        let flame = store.sessions(in: .flame)
        let prime = store.sessions(in: .prime)
        let stranger = store.sessions(in: .stranger)
        var seen = Set<String>()
        return (flame + prime + stranger)
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.isTop != rhs.isTop { return lhs.isTop }
                return lhs.lastMessageTimestamp > rhs.lastMessageTimestamp
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        // 半屏私聊叠加（对齐 H5 talkPopup 覆盖 messagePopup）—— 私聊 back 点击 = selectedChatPeer = nil，
        // 半屏消息列表保持可见（不关闭），符合用户"back 返回列表"预期
        .sheet(item: $selectedChatPeer, onDismiss: { chatSheetDetent = .medium }) { peer in
            ChatDetailContainer(
                peerYxAccId: peer.id,
                selfYxAccId: selfYxAccId,
                onClose: { selectedChatPeer = nil },
                sheetDetent: $chatSheetDetent
            )
            .giftPanelSheetBackground()
            .presentationDetents([.medium, .large], selection: $chatSheetDetent)
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Header（无关闭按钮，标题居中）

    private var header: some View {
        Text(L10n.liveRoomSheetMessagesTitle)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let sessions = allSessions
        if sessions.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sessions) { session in
                        MessageSessionRow(
                            session: session,
                            profile: store.profile(for: session.id),
                            onLongPress: {},
                            onTap: { selectedChatPeer = ChatSheetPeer(id: session.id) }
                        )
                        Divider().padding(.leading, 76).opacity(0.2)
                    }
                }
            }
            .refreshable { await store.load() }
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            EmptyStateView(textFont: .subheadline)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 半屏私聊 sheet(item:) 的 Identifiable wrapper —— peerYxAccId 即 id
fileprivate struct ChatSheetPeer: Identifiable {
    let id: String
}
