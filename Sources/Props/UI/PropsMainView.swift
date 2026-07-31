import SwiftUI

/// Props 虚拟道具主背包页（M1 Step 1b · spec §4.1 完整版）。
///
/// **对齐 H5** `views/virtualProps/index.vue`：
/// - Nav Bar：Back / Title "Virtual Props" / 右侧问号 → PropsRulesView
/// - Tab Bar：All / Frame / Vehicle / ChatSkin / CardFrame（Entrance 已注释）
/// - Grid：两列卡片，含 图片 / 名字 / Equipped 徽章（RTL 分支）/ 剩余时长（TimelineView 每分钟刷）/ Unlock lock icon / play preview 右上按钮
/// - 选中已拥有卡 → 底部 Equip/Unequip 条弹出（PropsBottomBar）
/// - Ops：前置校验拒绝 → toast；成功 → 视觉即时更新；API 失败 → toast + 回滚
/// - Preview：tap play icon → sheet 展开 SVGA/MP4/静图三分支（PropsPreviewSheet）
/// - Chat Skin 佩戴态：写 AnchorInfoStore.mine.chatBubble，消息场景立即应用；其余道具字段仍由各消费模块接入
struct PropsMainView: View {

    @StateObject private var store: PropsInventoryStore
    @State private var previewItem: PropItem?
    @State private var toastMessage: String?
    @State private var opsToastTask: Task<Void, Never>?
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dismiss) private var dismiss

    init(service: PropsService? = nil) {
        // M1 Step 1c 已落 LivePropsService（真接口 · PartyAPIClient + sapi 加密 + 401 自动 retry）
        let svc: PropsService = service ?? LivePropsService.shared
        _store = StateObject(wrappedValue: PropsInventoryStore(service: svc))
    }

    var body: some View {
        content
            .navigationBarBackButtonHidden(true)
            .swipeToPopEnabled()
            .background(Color(hex: 0x0B0010).ignoresSafeArea())
            .task { store.loadFirstIfNeeded() }
            .onDisappear {
                store.cancelInFlight()
                opsToastTask?.cancel()
            }
            .sheet(item: $previewItem) { item in
                PropsPreviewSheet(item: item, onClose: { previewItem = nil })
            }
    }

    // MARK: - 顶层结构

    @ViewBuilder private var content: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                navBar
                tabBar
                contentSwitch
            }

            // 底部 Equip/Unequip 条（对齐 H5 bottomBarVisible = chooseItem.isFromBag === 1）
            if let selected = selectedItem, selected.isFromBag == 1 {
                PropsBottomBar(
                    selected: selected,
                    isBusy: store.opsState.busyItemId == selected.id,
                    onTap: { handleOps(item: selected, action: $0) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Toast overlay
            if let msg = toastMessage {
                PropsToastView(message: msg)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedItem?.id)
        .animation(.easeInOut(duration: 0.2), value: toastMessage)
    }

    private var selectedItem: PropItem? {
        guard let id = store.chooseItemId else { return nil }
        return store.currentItems()?.first(where: { $0.id == id })
    }

    // MARK: - Nav Bar

    @ViewBuilder private var navBar: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Virtual Props")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .center)

            NavigationLink(value: WorkRoute.propsRules) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    // MARK: - Tab Bar

    @ViewBuilder private var tabBar: some View {
        HStack(spacing: 24) {
            ForEach(0..<PropTabItemType.tabOrder.count, id: \.self) { idx in
                let tab = PropTabItemType.tabOrder[idx]
                let title = tabTitle(for: tab)
                Button(action: { store.changeTab(tab) }) {
                    VStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 14, weight: store.currentTab == tab ? .semibold : .regular))
                            .foregroundStyle(store.currentTab == tab ? .white : Color.white.opacity(0.5))
                        Rectangle()
                            .fill(store.currentTab == tab ? Color(hex: 0xFFE600) : .clear)
                            .frame(width: 14, height: 4)
                            .clipShape(Capsule())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func tabTitle(for tab: PropTabItemType?) -> String {
        switch tab {
        case nil: return "All"
        case .frame: return "Frame"
        case .vehicle: return "Vehicle"
        case .chatSkin: return "Chat Skin"
        case .cardFrame: return "Card Frame"
        }
    }

    // MARK: - Content switch

    @ViewBuilder private var contentSwitch: some View {
        switch store.state {
        case .idle, .loading:
            ProgressView().progressViewStyle(.circular).tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            emptyView

        case .loaded(let items, _),
             .loadingMore(let items),
             .refreshing(let items):
            propsGrid(items: items)

        case .error(let items, _, let msg):
            if let items = items, !items.isEmpty {
                propsGrid(items: items)
                    .overlay(alignment: .top) {
                        Text(msg)
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color.red.opacity(0.7))
                            .clipShape(Capsule())
                            .padding(.top, 8)
                    }
            } else {
                VStack(spacing: 12) {
                    Text(msg).foregroundStyle(.white.opacity(0.7))
                    Button("Retry") { store.retry() }.foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.5))
            Text("No Props Yet")
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Grid

    @ViewBuilder private func propsGrid(items: [PropItem]) -> some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 15),
                GridItem(.flexible(), spacing: 15)
            ], spacing: 15) {
                ForEach(items) { item in
                    propCard(item: item)
                        .onTapGesture { store.chooseItemId = item.id }
                }
            }
            .padding(16)
            // 底部条占位 · 避免最后一行卡片被底部条挡
            if selectedItem?.isFromBag == 1 {
                Color.clear.frame(height: 72)
            }
        }
        .refreshable { await store.refreshAsync() }
    }

    // MARK: - PropCard（RTL badge + TimelineView 剩余时长每分钟刷 + play preview 按钮）

    @ViewBuilder private func propCard(item: PropItem) -> some View {
        let selected = store.chooseItemId == item.id
        let isRTL = layoutDirection == .rightToLeft

        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: isRTL ? .topLeading : .topLeading) {
                // 主图：itemSmallImg 优先，退到 itemImg
                CachedAsyncImage(
                    url: URL(string: item.itemSmallImg.isEmpty ? item.itemImg : item.itemSmallImg),
                    contentMode: .fit,
                    persistent: true
                ) {
                    Color(hex: 0x2A2530)
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Equipped 徽章 · RTL 分支（对齐 H5 index.vue:239 $language !== 'ar' 切换）
                if item.wearStatus == 1 {
                    equippedBadge(isRTL: isRTL)
                }

                // play preview 右上角（对齐 H5 卡片 play.webp）
                previewButton(item: item)
            }

            Text(item.itemName)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .lineLimit(1)

            // 剩余时长 · TimelineView 每分钟自动刷（spec F19 · 红队 d1-3）
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                HStack(spacing: 4) {
                    Image(systemName: item.isFromBag == 1 ? "clock" : "lock.fill")
                        .font(.system(size: 12))
                    Text(remainingText(for: item))
                        .font(.system(size: 12))
                }
                .foregroundStyle(item.isFromBag == 1 ? Color(hex: 0xFFC933) : Color.gray)
            }
        }
        .padding(10)
        .background(cardBackground(selected: selected))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    @ViewBuilder private func equippedBadge(isRTL: Bool) -> some View {
        let corners: RectangleCornerRadii = isRTL
            ? .init(topLeading: 0, bottomLeading: 8, bottomTrailing: 0, topTrailing: 6)
            : .init(topLeading: 6, bottomLeading: 0, bottomTrailing: 8, topTrailing: 0)

        Text("Equipped")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(
                LinearGradient(colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(UnevenRoundedRectangle(cornerRadii: corners))
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: isRTL ? .topTrailing : .topLeading)
    }

    @ViewBuilder private func previewButton(item: PropItem) -> some View {
        Button(action: { previewItem = item }) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.9), Color.black.opacity(0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    @ViewBuilder private func cardBackground(selected: Bool) -> some View {
        if selected {
            LinearGradient(colors: [Color(hex: 0x1C0529), Color(hex: 0x5C145B)],
                           startPoint: .top, endPoint: .bottom)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(hex: 0xFF0088), lineWidth: 1)
                )
        } else {
            Color(hex: 0x1F1B25)
        }
    }

    // MARK: - remaining text（H5 formatRemainingTime · 严格对齐 H5）

    private func remainingText(for item: PropItem) -> String {
        if item.isFromBag != 1 { return "Unlock" }
        if item.expireTime.isPermanent { return "Prem" }
        if let sec = item.expireTime.remainingSecondsFromNow() {
            return PropExpireTime.format(remaining: sec)
        }
        return "0D:00H:00M"
    }

    // MARK: - Ops handler（核心主链路）

    private func handleOps(item: PropItem, action: PropEquipAction) {
        Task {
            let result = await store.performOps(item: item, action: action)
            switch result {
            case .success:
                // 成功无 toast（对齐 H5 · 视觉即时反馈 badge + 底部条切）
                break
            case .rejected(let reason):
                showToast(reason.userMessage)
            }
        }
    }

    private func showToast(_ msg: String) {
        opsToastTask?.cancel()
        toastMessage = msg
        opsToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { toastMessage = nil }
        }
    }
}

// MARK: - RejectionReason → 用户文案（对齐 H5 三条 toast）

private extension PropsInventoryStore.RejectionReason {
    var userMessage: String {
        switch self {
        case .notOwned:                return "You cannot equip this item"
        case .alreadyWorn:             return "You already wear this"
        case .alreadyUnequipped:       return "You already unequip this"
        case .busy:                    return "Please wait..."
        case .permissionDenied:        return "This feature is unavailable"
        case .staleServerAuthoritative: return "Refreshing..."
        case .apiFailed(let msg):      return msg.isEmpty ? "Failed. Please try again." : msg
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("PropsMainView · Loaded (Fake)") {
    let fake = PropsServiceFake()
    fake.setPage(PropPage.previewSmall)
    return NavigationStack {
        PropsMainView(service: fake)
    }
    .preferredColorScheme(.dark)
}
#endif
