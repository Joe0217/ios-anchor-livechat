import SwiftUI

/// 派对房底部表情面板（F 里程碑 · 2026-07-17）。
///
/// **对齐 H5 蓝本** `livechat-h5/src/components/party/components/party-expression-popup.vue`：
/// - `van-popup position="bottom"` 底部半屏 sheet · min-h 50%（iOS 用 `.fraction(0.5)`）
/// - 上部 `v-swiper` 分类 × 分页拍平 · 每页固定 **4×3 = 12** 格
/// - 分类和表情按服务端返回内容完整展示，不按账号权限过滤
/// - 底部 tab bar 横向可滚 · 每 tab 圆形 24×24 · 激活 opacity 0.16 底色
/// - 单分类多页时展示自绘小圆点 indicator
///
/// **preflight**（[cross-scene-component-reuse-preflight] 已核）：无 CameraManager /
/// ignoresSafeArea / shared store 自持依赖 · 可作 sheet 半屏。
struct PartyExpressionPanel: View {
    @ObservedObject private var store = PartyStore.shared
    @Environment(\.dismiss) private var dismiss

    /// 当前分类 index（对应服务端返回的分类顺序）
    @State private var selectedClassIndex: Int = 0
    /// 当前分类下的分页 index（0-based · 每页 12 格）
    @State private var selectedPageIndex: Int = 0
    /// 玩法 resultImages 空时 toast 短提示
    @State private var toastMessage: String? = nil
    /// 每页固定 4×3 grid，避免不同分类或分页导致面板高度跳变。
    private let panelPageSize: Int = 12
    private let panelGridHeight: CGFloat = 200
    private let panelSheetHeight: CGFloat = 288

    var body: some View {
        VStack(spacing: 4) {
            content
                .padding(.top, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            tabBar
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            PartyAnalytics.track(
                "b_emoji_panel_open",
                properties: PartyAnalytics.roomProperties(
                    roomId: store.roomInfo?.id,
                    ownerId: store.roomInfo?.ownerId,
                    roomTempId: store.roomInfo?.roomTempId
                )
            )
            await store.loadExpressionList()
            selectDefaultExpressionTab()
        }
        .presentationDetents([.height(panelSheetHeight)])
        .overlay(alignment: .top) {
            if let msg = toastMessage {
                Text(msg)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
                    .padding(.top, 12)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.expressionListState {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tint(.white)
        case .error(let msg):
            VStack(spacing: 12) {
                Text(L10n.PartyRoom.emojiLoadFailed)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.7))
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button {
                    Task { await store.loadExpressionList() }
                } label: {
                    Text(L10n.PartyRoom.emojiRetry)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let classifications):
            if classifications.isEmpty {
                Color.clear
            } else {
                grid(for: classifications)
            }
        }
    }

    // MARK: - Grid（当前分类 × 当前分页）

    private func grid(for classifications: [PartyEmojiClassification]) -> some View {
        let idx = min(max(selectedClassIndex, 0), classifications.count - 1)
        let current = classifications[idx]
        let pages = paginate(current.emojisList, size: panelPageSize)
        let pageIdx = min(max(selectedPageIndex, 0), max(pages.count - 1, 0))

        return VStack(spacing: 8) {
            TabView(selection: $selectedPageIndex) {
                ForEach(pages.indices, id: \.self) { i in
                    gridPage(items: pages[i])
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: panelGridHeight)
            .highPriorityGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        let delta = value.translation.width < 0 ? 1 : -1
                        selectAdjacentTab(delta: delta, count: classifications.count)
                    }
            )

            // 分类页数 > 1 时展示 dot indicator
            if pages.count > 1 {
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { i in
                        Circle()
                            .fill(Color.white.opacity(i == pageIdx ? 0.9 : 0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                .frame(height: 8)
            } else {
                Color.clear.frame(height: 8)
            }
        }
    }

    /// 每页固定 4×3 grid；不足三行的内容顶对齐。
    private func gridPage(items: [PartyEmojiItem]) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
        return LazyVGrid(columns: cols, spacing: 16) {
            ForEach(items) { item in
                emojiCell(item: item)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func emojiCell(item: PartyEmojiItem) -> some View {
        Button {
            handleEmojiPick(item)
        } label: {
            CachedAsyncImage(url: URL(string: item.minImage ?? ""), contentMode: .fit) {
                Color.white.opacity(0.06)
            }
            .frame(width: 56, height: 56)
            .contentShape(Rectangle())    // 保证空白热区响应（[swiftui-button-plain-hitarea] rule）
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.id)
    }

    // MARK: - Tab bar（底部分类圆形 tab · 横向可滚）

    @ViewBuilder
    private var tabBar: some View {
        if case .loaded(let classifications) = store.expressionListState {
            if !classifications.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(classifications.indices, id: \.self) { i in
                            tabItem(classifications[i], selected: i == selectedClassIndex)
                                .onTapGesture {
                                    if selectedClassIndex != i {
                                        selectedClassIndex = i
                                        selectedPageIndex = 0
                                        let name = classifications[i].classType
                                        PartyAnalytics.track(
                                            "b_emoji_tab_switch",
                                            properties: [
                                                "tabname": name,
                                                "tabIndex": i,
                                                "classType": name,
                                            ]
                                        )
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: 32)
            } else {
                Color.clear.frame(height: 32)
            }
        } else {
            Color.clear.frame(height: 32)
        }
    }

    private func tabItem(_ classification: PartyEmojiClassification, selected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(selected ? Color.white.opacity(0.16) : Color.clear)
            CachedAsyncImage(url: URL(string: classification.coverImage ?? ""), contentMode: .fit) {
                Image(systemName: "face.smiling")
                    .foregroundColor(.white.opacity(0.5))
            }
            .frame(width: 24, height: 24)
        }
        .frame(width: 32, height: 32)
        .contentShape(Circle())
    }

    // MARK: - Pick handler

    private func handleEmojiPick(_ item: PartyEmojiItem) {
        // 107 审核模式开放完整表情协议，但不改变其他 Party 游戏权限。
        if item.isPlayEmoji, !canUsePlayEmoji {
            showToast(L10n.PartyRoom.emojiPlayError)
            return
        }
        // 玩法 -11 门槛：观众 tap 走 toast（对齐 H5 `usePartyHooks.js:1783` `inPartyRole > 0`）
        if item.isPlayEmoji, store.selfSeat == nil {
            showToast(L10n.PartyRoom.emojiOnSeatRequired)
            return
        }
        // 玩法 emoji resultImages 空 → toast（sendEmoji 也会守）
        if item.isPlayEmoji, (item.resultImages?.isEmpty ?? true) {
            showToast(L10n.PartyRoom.emojiPlayError)
            return
        }
        PartyAnalytics.track("b_emoji_mic_play", properties: ["emoji": item.id])
        store.sendEmoji(item)
        // 点选后即时关闭 sheet（对齐 H5 party-expression-popup.vue L98 close popup）
        dismiss()
    }

    // MARK: - Helpers

    private func showToast(_ msg: String) {
        withAnimation { toastMessage = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { toastMessage = nil }
        }
    }

    private var canUsePlayEmoji: Bool {
        PartyExpressionAvailability.canUsePlayEmoji
    }

    private func expressionClassificationIndex(in classifications: [PartyEmojiClassification]) -> Int? {
        if let index = classifications.firstIndex(where: { classification in
            !classification.emojisList.isEmpty
                && classification.emojisList.allSatisfy { !$0.isPlayEmoji }
        }) {
            return index
        }
        return classifications.firstIndex(where: { classification in
            classification.emojisList.contains { !$0.isPlayEmoji }
        })
    }

    /// 面板每次拉起按内容语义选中普通表情，不依赖服务端原始下标。
    private func selectDefaultExpressionTab() {
        selectedPageIndex = 0
        guard case .loaded(let classifications) = store.expressionListState,
              let expressionIndex = expressionClassificationIndex(in: classifications) else {
            selectedClassIndex = 0
            return
        }
        selectedClassIndex = expressionIndex
    }

    private func selectAdjacentTab(delta: Int, count: Int) {
        let next = selectedClassIndex + delta
        guard count > 0, next >= 0, next < count else { return }
        selectedClassIndex = next
        selectedPageIndex = 0
    }

    /// 按 pageSize 切页（每分类拍平为 N 页固定 4×3 grid）
    private func paginate(_ items: [PartyEmojiItem], size: Int) -> [[PartyEmojiItem]] {
        guard size > 0, !items.isEmpty else { return [] }
        var result: [[PartyEmojiItem]] = []
        var i = 0
        while i < items.count {
            let end = min(i + size, items.count)
            result.append(Array(items[i..<end]))
            i = end
        }
        return result
    }
}
