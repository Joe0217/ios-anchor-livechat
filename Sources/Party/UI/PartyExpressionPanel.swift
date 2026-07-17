import SwiftUI

/// 派对房底部表情面板（F 里程碑 · 2026-07-17）。
///
/// **对齐 H5 蓝本** `livechat-h5/src/components/party/components/party-expression-popup.vue`：
/// - `van-popup position="bottom"` 底部半屏 sheet · min-h 50%（iOS 用 `.fraction(0.5)`）
/// - 上部 `v-swiper` 分类 × 分页拍平 · 每页 **4×2 = 8** 格（`PARTY_PLAY_EMOJI.PANEL_PAGE_SIZE = 8`）
/// - 底部 tab bar 横向可滚 · 每 tab 圆形 24×24 · 激活 opacity 0.16 底色
/// - 单分类多页时展示自绘小圆点 indicator
///
/// **preflight**（[cross-scene-component-reuse-preflight] 已核）：无 CameraManager /
/// ignoresSafeArea / shared store 自持依赖 · 可作 sheet 半屏。
struct PartyExpressionPanel: View {
    @ObservedObject private var store = PartyStore.shared
    @Environment(\.dismiss) private var dismiss

    /// 当前分类 index（对应 `store.expressionListState.loaded` 里的 index）
    @State private var selectedClassIndex: Int = 0
    /// 当前分类下的分页 index（0-based · 每页 8 格）
    @State private var selectedPageIndex: Int = 0
    /// 玩法 resultImages 空时 toast 短提示
    @State private var toastMessage: String? = nil

    /// H5 侧 constant `PANEL_PAGE_SIZE = 8`（4×2 grid）
    private let panelPageSize: Int = 8

    var body: some View {
        VStack(spacing: 12) {
            content
            tabBar
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await store.loadExpressionList() }
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
            .frame(height: gridHeight)

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

    /// 每页 4×2 grid（对齐 H5 grid-cols-4）
    private func gridPage(items: [PartyEmojiItem]) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
        return LazyVGrid(columns: cols, spacing: 16) {
            ForEach(items) { item in
                emojiCell(item: item)
            }
        }
        .padding(.horizontal, 16)
    }

    private var gridHeight: CGFloat {
        // 2 行 × 每格 (56 + 上下 padding) ≈ 180；再加分页 padding 上下 8
        180
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
        if case .loaded(let classifications) = store.expressionListState, classifications.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(classifications.indices, id: \.self) { i in
                        tabItem(classifications[i], selected: i == selectedClassIndex)
                            .onTapGesture {
                                if selectedClassIndex != i {
                                    selectedClassIndex = i
                                    selectedPageIndex = 0
                                }
                            }
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 40)
        } else {
            Color.clear.frame(height: 40)
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
        .frame(width: 36, height: 36)
        .contentShape(Circle())
    }

    // MARK: - Pick handler

    private func handleEmojiPick(_ item: PartyEmojiItem) {
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
        store.sendEmoji(item)
        // 点选后即时关闭 sheet（对齐 H5 party-expression-popup.vue L98 close popup）
        dismiss()
    }

    private func showToast(_ msg: String) {
        withAnimation { toastMessage = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { toastMessage = nil }
        }
    }

    // MARK: - Helpers

    /// 按 pageSize 切页（对齐 H5 chunk 逻辑 · 每分类拍平为 N 页 4×2 grid）
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
