import SwiftUI

/// 派对房搜索页（E 增强 v3 · 对齐 H5 用户端 `livechat-h5/src/views/party/search.vue`）。
///
/// **视觉**：自定义顶部条（隐藏系统 nav bar），back 箭头与搜索框同一行；搜索框圆角胶囊 H36 · 半透明白底 + 白描边
/// **交互**：回车触发搜索（`.onSubmit`）+ Store 层 1500ms throttle；空搜结果显 empty 空态卡
struct PartySearchView: View {
    @StateObject private var store = PartySearchStore()
    /// v4：传完整对象让上层判密码房前置弹窗
    let onTapRoom: (PartyRoomInfo) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            Theme.Palette.partyListBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                content
                Spacer(minLength: 0)
            }

            if case .searching = store.state {
                loadingOverlay
            }
        }
        .navigationBarHidden(true)
        .swipeToPopEnabled()
        .onAppear {
            // 进页面自动聚焦（对齐 H5 用户体验：直接可打字）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                searchFocused = true
            }
        }
    }

    // MARK: - 顶部条（back + 搜索框同一行；对齐 H5 g-nav-bar 布局）

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            searchField
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// 搜索框（对齐 H5 search.vue `<input>` 圆角胶囊 H36 · 白 0.15 底 · 白 0.3 描边）
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
                .padding(.leading, 12)

            TextField(
                "",
                text: $store.query,
                prompt: Text(L10n.Party.searchPlaceholder).foregroundColor(.white.opacity(0.5))
            )
            .textFieldStyle(.plain)
            .foregroundColor(.white)
            .font(.system(size: 14))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.search)
            .focused($searchFocused)
            .onSubmit { store.search() }

            if !store.query.isEmpty {
                Button {
                    store.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.trailing, 8)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 8)
            }
        }
        .frame(height: 36)
        .background(Capsule().fill(Color.white.opacity(0.15)))
        .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle:
            // 未搜索过 → 空白（无搜索历史/推荐词等）
            EmptyView()
        case .searching:
            // loading 用全屏 overlay 展示，此处占位保布局
            Color.clear
        case .result(let rooms, _):
            resultList(rooms: rooms)
        case .empty:
            emptyView
        case .error(let msg, _):
            errorView(msg: msg)
        }
    }

    private func resultList(rooms: [PartyRoomInfo]) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(rooms, id: \.stableListId) { room in
                    Button {
                        onTapRoom(room)
                    } label: {
                        PartyRoomCardView(
                            room: room,
                            languageName: room.roomLanguage ?? L10n.Party.listPillLanguageFallback,
                            isMyRoom: false
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                Color.clear.frame(height: 40)
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    /// 空态：搜索过 + 无结果
    private var emptyView: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 42))
                .foregroundColor(Theme.Palette.partyGreeting)
            Text(L10n.Party.searchNoResults)
                .font(.system(size: 14))
                .foregroundColor(Theme.Palette.partyGreeting)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// 错误态：与 empty 视觉一致（H5 catch 里也是清 list，用户体验对齐"没结果"）
    private func errorView(msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text(msg)
                .font(.system(size: 13))
                .foregroundColor(Theme.Palette.partyGreeting)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// 全屏 loading overlay（对齐 H5 `<g-loading v-if="isSearchLoading" />`）
    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            ProgressView()
                .tint(.white)
                .scaleEffect(1.2)
        }
    }
}
