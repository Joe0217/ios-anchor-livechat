import SwiftUI

/// Sheet 外壳 —— 标题 + 双 tab bar + 内容切换 + 规则 overlay + PreviewProvider。
///
/// 对齐 H5 `girlWeeklyTask.vue`:
/// - 面板高度:H5 h-460;iOS `.fraction(0.4)` 单 detent 政策(spec §3.1 v2)
/// - 背景:240deg 3-color linear-gradient (#17175A → #1D0E4C → #130A2A)
/// - 双 tab bar 选中色不同:LiveGift → white / Tycoon → #FF0090
/// - 右上问号按钮 → 中心 overlay 显规则,tap OK / VoiceOver escape 关闭
struct LiveGiftTaskSheet: View {
    // 外部注入(NIMChatroomManager `let` 持有)
    @ObservedObject var store: LiveGiftTaskStore
    let anchorId: String
    @Binding var isPresented: Bool
    let onUserTap: (String) -> Void

    // 内部 sheet 生命周期
    @StateObject private var sheetStore = LiveGiftTaskSheetStore()
    @StateObject private var historyStore = LiveGiftTaskHistoryStore()
    @StateObject private var tycoonStore = ActiveTycoonTaskStore()

    var body: some View {
        ZStack {
            backgroundLayer
            contentLayer
            if sheetStore.showRule {
                ruleOverlay
                    .transition(.opacity)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape) {
                        sheetStore.showRule = false
                    }
            }
        }
        .onAppear {
            sheetStore.onPresent()
            Task { await historyStore.refreshAsync(anchorUserId: anchorId) }
            // H5 的 ActiveTycoonTaskTab 在 popup 创建时就执行 immediate load，
            // 因此切到第二个 tab 时不会额外等待首个请求。
            Task { await tycoonStore.loadAsync() }
        }
        .onChange(of: sheetStore.activeTab) { newTab in
            if newTab == .activeTycoon {
                Task { await tycoonStore.loadAsync() }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: sheetStore.showRule)
    }

    // MARK: - 背景层(H5 240deg 3-color 渐变)

    private var backgroundLayer: some View {
        LinearGradient(
            colors: [Color(hex: 0x17175A), Color(hex: 0x1D0E4C), Color(hex: 0x130A2A)],
            startPoint: .topTrailing, endPoint: .bottomLeading
        )
        .ignoresSafeArea()
    }

    // MARK: - 内容层

    private var contentLayer: some View {
        VStack(spacing: 0) {
            sheetHeader
            tabBar
            tabContent
        }
    }

    @ViewBuilder
    private var sheetHeader: some View {
        HStack {
            Spacer()
            Text(L10n.liveRoomTaskSheetTitle)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
            Spacer()
        }
        .overlay(alignment: .trailing) {
            Button {
                sheetStore.showRule = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .foregroundColor(.white.opacity(0.8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 15)
            .accessibilityLabel(L10n.liveRoomTaskRulesButton)
        }
        .padding(.top, 20)
    }

    @ViewBuilder
    private var tabBar: some View {
        HStack(spacing: 16) {
            tabButton(tab: .liveGift,
                      title: L10n.liveRoomTaskTabLiveGift,
                      selectedColor: .white)
            tabButton(tab: .activeTycoon,
                      title: L10n.liveRoomTaskTabActiveTycoon,
                      selectedColor: Color(hex: 0xFF0090))
            Spacer()
        }
        .padding(.horizontal, 15)
        .padding(.top, 12)
    }

    @ViewBuilder
    private func tabButton(tab: LiveGiftTaskSheetStore.Tab, title: String, selectedColor: Color) -> some View {
        Button {
            sheetStore.switchTab(tab)
        } label: {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(sheetStore.activeTab == tab ? selectedColor : .white.opacity(0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tabContent: some View {
        Group {
            switch sheetStore.activeTab {
            case .liveGift:
                LiveGiftTaskTab1View(giftTask: store.giftTask,
                                     historyStore: historyStore,
                                     anchorId: anchorId,
                                     onUserTap: onUserTap)
            case .activeTycoon:
                LiveGiftTaskTab2View(store: tycoonStore)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - 规则 overlay(居中卡片 + dim 背景)

    @ViewBuilder
    private var ruleOverlay: some View {
        ZStack {
            // Dim 背景层(tap 关闭)
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { sheetStore.showRule = false }
            // 卡片
            VStack(spacing: 12) {
                Text(ruleTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Text(ruleBody)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.8))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Button {
                    sheetStore.showRule = false
                } label: {
                    Text(L10n.liveRoomTaskRulesButton)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            LinearGradient(colors: [Color(hex: 0xFF9438), Color(hex: 0xFE00DE)],
                                          startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
            }
            .padding(20)
            .frame(width: 320)
            .background(
                LinearGradient(colors: [Color(hex: 0x17175A), Color(hex: 0x1D0E4C), Color(hex: 0x130A2A)],
                              startPoint: .topTrailing, endPoint: .bottomLeading)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.5), radius: 20)
        }
    }

    private var ruleTitle: String {
        sheetStore.activeTab == .activeTycoon
            ? L10n.liveRoomTaskRulesTitleTycoon
            : L10n.liveRoomTaskRulesTitleLiveGift
    }

    private var ruleBody: String {
        if sheetStore.activeTab == .activeTycoon {
            let dynamic = tycoonStore.firstTaskRuleText()
            if !dynamic.isEmpty {
                return dynamic
            }
            return L10n.liveRoomTaskRulesBodyTycoon
        }
        return L10n.liveRoomTaskRulesBodyLiveGift
    }
}

// MARK: - Preview

#if DEBUG
struct LiveGiftTaskSheet_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            LiveGiftTaskSheet(
                store: {
                    let s = LiveGiftTaskStore()
                    s.loadInitial(anchorUserId: "1")
                    return s
                }(),
                anchorId: "1",
                isPresented: .constant(true),
                onUserTap: { _ in }
            )
            .previewDisplayName("Loaded")

            LiveGiftTaskSheet(
                store: LiveGiftTaskStore(service: LiveGiftTaskServiceFakes(mode: .empty)),
                anchorId: "1",
                isPresented: .constant(true),
                onUserTap: { _ in }
            )
            .previewDisplayName("Empty")
        }
    }
}
#endif
