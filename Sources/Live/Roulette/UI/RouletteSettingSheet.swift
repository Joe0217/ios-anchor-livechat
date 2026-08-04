import SwiftUI

/// Roulette 主 sheet（对齐 H5 [liveRoulettePopup.vue] 完整功能）
///
/// 从上到下：
/// - Header：左 ? 图标（重开引导）+ 中间 "Set Interaction Wheel" + 右占位
/// - Central：RouletteWheelView 转盘可视化
/// - Price row：钻石图 + 可编辑价格输入框
/// - Edit Wheel 按钮（渐变边框 outline）
/// - Main button 三态（Enable / Finish Editing / disabled 灰态）
/// - Close Wheel 按钮（enabled 才显示）
/// - 底部 Toast overlay（2s 自消）
struct RouletteSettingSheet: View {
    @StateObject private var store: RouletteStore
    @Binding var isPresented: Bool

    /// 编辑子 sheet 显示
    @State private var showEditSheet: Bool = false
    /// 重开引导 popup 显示（点 ? 图标）
    @State private var showIntroReopen: Bool = false
    /// 价格 TextField 绑定 text 版（对齐 H5 diamondCount）
    @State private var priceText: String = ""
    @FocusState private var priceFocused: Bool

    /// 启用状态变化回调（Enable/Close/Save 成功、savedConfig.enabled 有变化时触发，供 LiveRoomView 顶部 icon 两态切换）
    let onEnabledChanged: ((Bool) -> Void)?
    /// Enable 成功后 sheet 立即关闭，toast 需上抛到 LiveRoomView 全屏层显示（sheet 内 overlay 会随 sheet dismount 一起消失）
    let onToast: ((String) -> Void)?

    init(anchorUserId: String,
         liveRoomId: String,
         isPresented: Binding<Bool>,
         onEnabledChanged: ((Bool) -> Void)? = nil,
         onToast: ((String) -> Void)? = nil) {
        self._store = StateObject(wrappedValue: RouletteStore(anchorUserId: anchorUserId,
                                                              liveRoomId: liveRoomId))
        self._isPresented = isPresented
        self.onEnabledChanged = onEnabledChanged
        self.onToast = onToast
    }

    var body: some View {
        ZStack {
            content
            toastOverlay
        }
        .onAppear(perform: handleAppear)
        .onChange(of: store.state, perform: handleStateChange)
        .onChange(of: store.savedConfig.enabled) { newValue in
            onEnabledChanged?(newValue)
        }
        .sheet(isPresented: $showEditSheet) {
            RouletteEditSheet(store: store, isPresented: $showEditSheet)
                .giftPanelSheetBackground()
                .presentationDetents([.fraction(0.5), .fraction(0.8)])
                .presentationDragIndicator(.visible)
        }
        .overlay {
            RouletteIntroPopup(isPresented: $showIntroReopen, onFinish: {
                showIntroReopen = false
            })
        }
    }

    // MARK: - content

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading:
            ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            configForm
        case .error:
            errorView
        }
    }

    private var configForm: some View {
        // ScrollView 包裹：sheet detent 0.65 高度下若内容超出（大屏 iPad / 大字号 / 键盘弹起）允许纵向滚动
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                header
                RouletteWheelView(sectors: store.displaySectors)
                    .padding(.vertical, 10)
                priceRow
                editButton
                mainButton
                if store.closeButtonVisible {
                    closeButton
                }
            }
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 20)
        }
    }

    // MARK: - sub views

    private var header: some View {
        ZStack {
            HStack {
                Button(action: reopenIntro) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.liveRoomRouletteRules))
                Spacer()
            }
            Text(L10n.liveRoomRouletteSettingTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private var priceRow: some View {
        HStack(spacing: 6) {
            CDNAssetImage("coins")
                .resizable().frame(width: 18, height: 18)
            TextField("", text: $priceText,
                      prompt: Text(L10n.liveRoomRoulettePrice)
                        .foregroundColor(.white.opacity(0.3)))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
                .focused($priceFocused)
                .frame(maxWidth: 120)
                .onChange(of: priceText, perform: handlePriceChange)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Color(hex: 0x101010), in: Capsule())
    }

    private var editButton: some View {
        Button(action: openEditSheet) {
            HStack(spacing: 6) {
                Image(systemName: "pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(L10n.liveRoomRouletteEdit)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .stroke(
                        LinearGradient(colors: [Color(hex: 0x8E60E6), Color(hex: 0xD074E9)],
                                       startPoint: .leading, endPoint: .trailing),
                        lineWidth: 1.5
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var mainButton: some View {
        switch store.mainButtonKind {
        case .disabled:
            mainButtonLabel(text: L10n.liveRoomRouletteEnable,
                            background: AnyShapeStyle(Color.white.opacity(0.1)),
                            textOpacity: 0.3)
                .allowsHitTesting(false)
        case .enable:
            Button(action: handleEnable) {
                mainButtonLabel(text: L10n.liveRoomRouletteEnable,
                                background: mainButtonGradient,
                                textOpacity: 1.0)
            }
            .buttonStyle(.plain)
            .disabled(store.isSaving)
        case .finishEditing:
            Button(action: handleFinishEditing) {
                mainButtonLabel(text: L10n.liveRoomRouletteFinishEditing,
                                background: mainButtonGradient,
                                textOpacity: 1.0)
            }
            .buttonStyle(.plain)
            .disabled(store.isSaving)
        }
    }

    private func mainButtonLabel(text: String, background: AnyShapeStyle, textOpacity: Double) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white.opacity(textOpacity))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(background, in: Capsule())
    }

    private var mainButtonGradient: AnyShapeStyle {
        AnyShapeStyle(
            LinearGradient(colors: [Color(hex: 0x8E60E6), Color(hex: 0xD074E9)],
                           startPoint: .leading, endPoint: .trailing)
        )
    }

    private var closeButton: some View {
        Button(action: handleClose) {
            Text(L10n.liveRoomRouletteCloseWheel)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(hex: 0x4F4267), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(store.isSaving)
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Text(L10n.liveRoomRouletteErrorRetry)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
            Button(action: store.retry) {
                Text(L10n.liveRoomRetry)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24).padding(.vertical, 8)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = store.toast {
            VStack {
                Spacer()
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.black.opacity(0.7), in: Capsule())
                    .padding(.bottom, 40)
            }
            .transition(.opacity)
        }
    }

    // MARK: - handlers

    private func handleAppear() {
        store.loadIfNeeded()
    }

    /// state 从 loading → loaded 时同步服务端价格到本地 TextField
    private func handleStateChange(_ newState: RouletteStore.LoadState) {
        if case .loaded = newState, priceText.isEmpty, store.savedConfig.price > 0 {
            priceText = String(store.savedConfig.price)
        }
    }

    private func handlePriceChange(_ newValue: String) {
        // 仅收数字（对齐 H5 diamond input 语义）
        let digits = newValue.filter { $0.isNumber }
        if digits != newValue { priceText = digits }
        store.updateDraftPrice(Int(digits) ?? 0)
    }

    private func openEditSheet() {
        priceFocused = false
        guard store.requirePrice() else { return }
        Task {
            await store.reloadSectorsForEditing()
            showEditSheet = true
        }
    }

    private func handleEnable() {
        priceFocused = false
        Task {
            let succeeded = await store.enableWheel()
            // 成功后立即关 sheet + 上抛 toast 到 LiveRoomView（sheet 内 overlay toast 会随 dismount 消失）
            // 失败态：不关 sheet，保留 sheet 内 store.toast 显示错误
            guard succeeded else { return }
            isPresented = false
            onToast?(L10n.liveRoomRouletteToastStarted)
        }
    }

    private func handleFinishEditing() {
        priceFocused = false
        Task {
            let succeeded = await store.finishEditing()
            // 对齐 H5 finishEditingBtn：保存成功后关闭外层转盘设置，并在全局层展示成功提示。
            guard succeeded else { return }
            isPresented = false
            onToast?(L10n.liveRoomRouletteToastStarted)
        }
    }

    private func handleClose() {
        priceFocused = false
        Task {
            let succeeded = await store.closeWheel()
            // 成功后立即关 sheet + 上抛 toast（对齐 H5 closeWheelBtn emit('closePopup')）
            // closeWheel 成功后 savedConfig.enabled=false；失败保留 true 让 sheet 内 toast 显示错误
            guard succeeded else { return }
            isPresented = false
            onToast?(L10n.liveRoomRouletteToastStopped)
        }
    }

    private func reopenIntro() {
        showIntroReopen = true
    }
}
