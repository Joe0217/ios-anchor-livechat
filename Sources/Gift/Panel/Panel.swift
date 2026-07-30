import SwiftUI

/// 公共礼物面板主 sheet（spec §3 UI 结构）。
///
/// 调用方通过 `CommonGiftPanelConfig` 便利工厂配置：
/// - `.callGate(minPrice:initialSelection:onConfirm:)`
/// - `.wishGift(onConfirm:)`
/// - `.liveDisplayOnly`
/// - `.imBind(service:onSelect:onCancel:)`
/// - `.partySend(...)` / `.callAskFor(...)` — H+ 占位
///
/// 挂载方式（对齐 spec §0.4 preflight）：`.sheet(isPresented:)` 挂 `[.medium]` 或 `[.large]` detents。
/// **禁**用 `fullScreenCover`（会盖 tab / 违反 swiftui-fullscreencover-hoist rule）。
struct CommonGiftPanel: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: CommonGiftPanelStore

    init(config: CommonGiftPanelConfig) {
        _store = StateObject(wrappedValue: CommonGiftPanelStore(config: config))
    }

    var body: some View {
        ZStack {
            // 底部渐变背景（对齐设计稿深紫底）
            LinearGradient(
                colors: [
                    Theme.Palette.liveTopPurple,
                    Theme.Palette.liveMidPurple,
                    Theme.Palette.liveBottomDark
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                if store.config.receivers != nil {
                    GiftPanelReceiverRow(store: store)
                        .background(Color.white.opacity(0.02))
                }
                GiftPanelTopBar(store: store)
                gridArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if shouldRenderFooter {
                    Divider().background(Color.white.opacity(0.08))
                    GiftPanelFooter(store: store)
                }
            }
        }
        .task {
            if store.config.backpack.isVisible {
                store.config.onBackpackEntryShown?()
            }
            await store.load()
        }
        .onChange(of: store.phase) { newPhase in
            // sent 态 → 自动 dismiss（onSend/onConfirm/onSelect/onAsk 已在 store 内部触发完毕）
            if newPhase == .sent {
                dismiss()
            }
        }
        .onDisappear {
            // ×/swipe/onChange dismiss 三条路径都会走这里；仅当没完成 action 才触发 onDismiss（IM 场景 = onCancel）
            if !store.didCompleteAction {
                store.config.onDismiss?()
            }
        }
        .preferredColorScheme(.dark)
    }
    // 注：`.presentationDetents` / `.presentationDragIndicator` 由调用方在 .sheet 内层挂
    // （直播中 [.fraction(0.4), .large]；心愿单/开播 [.fraction(0.5), .large]；IM .large）

    // MARK: - Sub views

    @ViewBuilder
    private var gridArea: some View {
        switch store.phase {
        case .initial, .loading:
            ProgressView()
                .tint(.white)
                .scaleEffect(1.2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loadFailed(let msg):
            errorView(msg)
        case .loaded, .sending, .sent, .sendFailed, .insufficientBalance:
            loadedGridArea
        }
    }

    /// v2（2026-07-09）：多 tab 场景用 `TabView(.page)` 支持横滑切换（对齐 H5 newGiftsPopup v-swiper）；
    /// 单 tab 场景保持直渲，避免 TabView page 容器开销。
    @ViewBuilder
    private var loadedGridArea: some View {
        if store.config.tabs.count > 1 {
            TabView(selection: currentTabBinding) {
                ForEach(store.config.tabs, id: \.self) { tab in
                    tabPage(for: tab).tag(tab)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        } else {
            let onlyTab = store.config.tabs.first ?? .popular
            tabPage(for: onlyTab)
        }
    }

    /// 单 tab page：非空时渲 grid，空时 emptyView
    @ViewBuilder
    private func tabPage(for tab: GiftPanelTab) -> some View {
        if store.gifts(for: tab).isEmpty {
            emptyView
        } else {
            GiftPanelGrid(store: store, tab: tab)
        }
    }

    /// `TabView.selection` 双向绑定 store.currentTab（get 直读，set 走 `store.switchTab(_:)` 保 invariant）
    private var currentTabBinding: Binding<GiftPanelTab> {
        Binding(
            get: { store.currentTab },
            set: { store.switchTab($0) }
        )
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.yellow.opacity(0.8))
            Text(msg)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(action: { Task { await store.load() } }) {
                Text(L10n.giftPickerRetry)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.15)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        EmptyStateView(style: .compact, textFont: .system(size: 13))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Layout helpers

    private var shouldRenderFooter: Bool {
        switch store.config.footer {
        case .none, .instantSelect: return false
        default: return true
        }
    }
}

// MARK: - Preview

#if DEBUG
struct CommonGiftPanel_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            CommonGiftPanel(config: .callGate(minPrice: 0, initialSelection: nil, onConfirm: { _ in }))
                .previewDisplayName("callGate")

            CommonGiftPanel(config: .wishGift(onConfirm: { _, _ in }))
                .previewDisplayName("wishGift")

            CommonGiftPanel(config: .liveDisplayOnly)
                .previewDisplayName("liveDisplayOnly")
        }
        .preferredColorScheme(.dark)
    }
}
#endif
