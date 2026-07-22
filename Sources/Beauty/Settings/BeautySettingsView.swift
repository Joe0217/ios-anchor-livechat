import SwiftUI

/// K spec H5 对齐版（2026-07-02）：美颜设置页根 View。
///
/// **信息架构**（对齐 H5 beautySettings 截图）：
/// - 全屏预览（ignoresSafeArea）
/// - 顶部左：半透明黑圆 × 关闭按钮 / 顶部右：紫→红渐变 `Save` 胶囊
/// - 底部深紫 sheet：3 个 tab (`Beauty Effects` / `Face Shaping` / `Filter`) + 参数图标横滑行
/// - **单顶部 slider**：绑当前选中参数，位于 sheet 上方；左侧红色 Toggle 是全局开关
/// - Recover 是 icon row 首位，点击重置本 tab 参数
///
/// **保存语义**（2026-07-08 用户澄清）：
/// - 拖 slider / 切 filter / 换 sticker / Recover 全部**只改 store in-memory**，不写盘（预览实时更新）
/// - 顶部 `Save` 按钮才触发 `store.flushIfDirty()` 写盘
/// - X 按钮：若 `store.isDirty` → 弹 `exitConfirm` 二次确认（`Exit` 丢弃 / `Continue Editing` 返回）
///   → `Exit` 走 `store.revert()` 恢复磁盘值；不 dirty 则直接 dismiss
/// - onDisappear（真 dismount）兜底 `store.revert()`：防止未保存 in-memory 状态残留影响下次进入
///
/// 关键契约保留：
/// - Slider 锁 LTR（红队 B3）—— `.environment(\.layoutDirection, .leftToRight)`
/// - CameraManager 灯熄（红队 E5）—— onDisappear stop
/// - Sharer attach/detach `.preview` token（红队 B1）
/// - 拖动 slider 直调 `camera.renderer.apply(60ms throttle)` 兜底 Sharer 中转
struct BeautySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var camera = CameraManager()
    @ObservedObject private var sharer: BeautyPipelineSharer
    @ObservedObject private var store: BeautySettingsStore

    @State private var selectedTab: Tab = .skin
    /// Skin/Shape tab 当前选中的参数 id；nil = 顶部 slider disabled
    @State private var selectedSkinParamId: String? = "blur"
    @State private var selectedShapeParamId: String? = "cheekV"
    /// Recover 确认弹窗目标；nil = 弹窗不显示（需求 2）
    @State private var pendingRecover: RecoverTarget?
    /// X 按钮触发的 exit confirm 弹窗展示态（dirty 时才弹）
    @State private var showExitConfirm: Bool = false
    /// Save 按钮写盘失败时的 error alert 展示态（防 silent data loss，对齐 error-handling.md）
    @State private var showSaveError: Bool = false
    /// 只有拿到相机授权后才创建预览并开放美颜参数操作。
    @State private var isCameraAuthorized: Bool = false
    /// 系统授权弹窗异步返回时，页面可能已经被 pop；必须在真离页时取消，避免重新启动相机。
    @State private var authorizationTask: Task<Void, Never>?

    enum Tab: Int, Hashable, CaseIterable {
        case skin = 0, shape, filter, sticker

        var label: String {
            switch self {
            case .skin:    return L10n.BeautySettings.tabSkin
            case .shape:   return L10n.BeautySettings.tabShape
            case .filter:  return L10n.BeautySettings.tabFilter
            case .sticker: return L10n.BeautySettings.tabSticker
            }
        }
    }

    /// Recover 确认弹窗目标（需求 2：按 tab 分组 reset）
    enum RecoverTarget: Identifiable {
        case skin, shape
        var id: String { self == .skin ? "skin" : "shape" }
    }

    init(sharer: BeautyPipelineSharer = .shared) {
        self.sharer = sharer
        self.store = sharer.store
    }

    var body: some View {
        ZStack {
            if isCameraAuthorized {
                // 全屏预览
                BeautyPreviewPanel(camera: camera, sharer: sharer)
                    .ignoresSafeArea()

                // 顶部悬浮：X + Save
                VStack {
                    topBar
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    Spacer()
                }

                // 底部 sheet
                VStack(spacing: 0) {
                    Spacer()
                    toggleAndSlider
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                    sheetContent
                }
            } else {
                // 授权弹窗返回前仍提供退出路径；拒绝后会自动返回上一页再展示权限提示。
                VStack {
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(Color.black.opacity(0.4), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.commonBack)

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    Spacer()
                }
            }
        }
        .navigationBarHidden(true)
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            requestCameraPermission()
        }
        .onDisappear {
            // v5.3.3 双守卫：切后台 SwiftUI 也会调 onDisappear（snapshot 用），仅在真 dismount 时清理
            guard scenePhase != .background else { return }
            authorizationTask?.cancel()
            authorizationTask = nil
            guard isCameraAuthorized else { return }
            // 保存语义：真 dismount 时兜底 revert 未保存修改（若用户绕过 X 按钮走系统 back gesture / 上级 pop）
            store.revert()
            sharer.detach(camera.renderer as AnyObject & BeautyRenderer)
            camera.stop()
        }
        // Slider 拖动实时更新 SDK（60ms throttle 直调 renderer.apply）
        .onReceive(
            store.objectWillChange
                .throttle(for: 0.06, scheduler: DispatchQueue.main, latest: true)
        ) { _ in
            if isCameraAuthorized {
                camera.renderer.apply(store.settings)
            }
        }
        // 需求 2: Recover 二次确认弹窗
        .alert(
            L10n.BeautySettings.recoverConfirmTitle,
            isPresented: Binding(
                get: { pendingRecover != nil },
                set: { if !$0 { pendingRecover = nil } }
            ),
            presenting: pendingRecover
        ) { target in
            Button(L10n.BeautySettings.recoverConfirmYes, role: .destructive) {
                switch target {
                case .skin:  resetSkin()
                case .shape: resetShape()
                }
            }
            Button(L10n.BeautySettings.recoverConfirmNo, role: .cancel) {}
        } message: { _ in
            Text(L10n.BeautySettings.recoverConfirmMessage)
        }
        // X 按钮 exit confirm：dirty 时弹（对齐 H5 index.vue:199-210 goBack）
        .alert(
            L10n.BeautySettings.exitConfirmTitle,
            isPresented: $showExitConfirm
        ) {
            Button(L10n.BeautySettings.exitConfirmDiscard, role: .destructive) {
                store.revert()   // 恢复磁盘值（onDisappear 兜底再调一次是幂等）
                dismiss()
            }
            Button(L10n.BeautySettings.exitConfirmContinue, role: .cancel) {}
        } message: {
            Text(L10n.BeautySettings.exitConfirmMessage)
        }
        // Save 写盘失败 error alert（防 silent data loss；SwiftUI 空 actions 会自动加本地化 OK 按钮）
        .alert(
            L10n.BeautySettings.errorPersistenceWriteFailed,
            isPresented: $showSaveError
        ) {} message: {
            if let error = store.lastPersistenceError {
                Text(String(describing: error))
            }
        }
    }

    private func requestCameraPermission() {
        authorizationTask?.cancel()
        authorizationTask = Task { @MainActor in
            guard await MediaPermissionGate.requestAccess(for: .camera) else {
                guard !Task.isCancelled else { return }
                dismiss()
                MediaPermissionAlertCenter.shared.presentAfterCurrentPageDismissal(for: .camera)
                return
            }
            guard !Task.isCancelled else { return }
            isCameraAuthorized = true
            camera.start()
            sharer.attach(camera.renderer as AnyObject & BeautyRenderer, token: .preview)
            if camera.isBeautyFallback {
                sharer.reportSetupResult(.failure(.genericSetupFailed))
            } else {
                sharer.reportSetupResult(.success(()))
            }
            camera.renderer.apply(store.settings)  // 首帧一致
        }
    }

    // MARK: - 顶部 X + Save

    private var topBar: some View {
        HStack {
            Button {
                // 保存语义：dirty 时弹 exitConfirm；无修改则直接 dismiss（onDisappear 内 revert 是幂等 no-op）
                if store.isDirty {
                    showExitConfirm = true
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.commonBack)

            Spacer()

            Button {
                // Save 语义：显式检查写盘错误，避免用户改动因磁盘写失败被静默丢弃
                // （store.lastPersistenceError 由 flushIfDirty catch 分支设置，成功清 nil）
                _ = store.flushIfDirty()
                if store.lastPersistenceError != nil {
                    showSaveError = true   // 停在页面，让用户看到失败反馈
                } else {
                    dismiss()
                }
            } label: {
                Text(L10n.BeautySettings.save)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(
                        LinearGradient(
                            colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Toggle + 单 Slider（悬浮在 sheet 上方）

    private var toggleAndSlider: some View {
        HStack(spacing: 12) {
            // 全局美颜开关（红色系，对齐 H5 视觉）
            Toggle("", isOn: Binding(
                get: { store.settings.enabled },
                set: { newValue in store.mutate { $0.enabled = newValue } }
            ))
            .labelsHidden()
            .tint(Theme.Palette.brandPinkA)

            // 单 Slider：绑当前选中参数（skin/shape 从 catalog；filter 绑 filterLevel）
            currentSlider
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    /// 顶部 slider —— 根据 selectedTab 分派
    @ViewBuilder
    private var currentSlider: some View {
        switch selectedTab {
        case .skin:
            paramSlider(entry: skinEntry(), tint: Theme.Palette.brandPinkA)
        case .shape:
            paramSlider(entry: shapeEntry(), tint: Theme.Palette.brandPinkA)
        case .filter:
            filterLevelSlider
        case .sticker:
            // 贴纸 tab 无强度概念，slider disabled
            Slider(value: .constant(0), in: 0...100)
                .tint(Theme.Palette.brandPinkA)
                .disabled(true)
        }
    }

    private func skinEntry() -> BeautyParamEntry? {
        BeautyParamCatalog.skinParams.first { $0.id == selectedSkinParamId }
    }

    private func shapeEntry() -> BeautyParamEntry? {
        BeautyParamCatalog.shapeParams.first { $0.id == selectedShapeParamId }
    }

    /// Skin/Shape 参数 slider
    private func paramSlider(entry: BeautyParamEntry?, tint: Color) -> some View {
        Slider(
            value: Binding(
                get: { entry.map { $0.get(store.settings) } ?? 0 },
                set: { newValue in
                    guard let entry else { return }
                    store.mutate { entry.set(&$0, newValue) }
                }
            ),
            in: entry?.range ?? 0...100
        )
        .tint(tint)
        .disabled(entry == nil || !store.settings.enabled)
    }

    /// Filter tab 顶部 slider —— 绑 filterLevel（origin 时 disabled）
    private var filterLevelSlider: some View {
        Slider(
            value: Binding(
                get: { store.settings.filterLevel },
                set: { newValue in store.mutate { $0.filterLevel = newValue } }
            ),
            in: 0...100
        )
        .tint(Theme.Palette.brandPinkA)
        .disabled(!store.settings.enabled || store.settings.filterName == FilterKey.origin)
    }

    // MARK: - 深紫 sheet 内容

    private var sheetContent: some View {
        VStack(spacing: 0) {
            tabBar
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)

            // 参数图标行 or 滤镜缩略图 or 贴纸（switch 保持 identity，切 tab 不重建）
            ZStack {
                iconRow(params: BeautyParamCatalog.skinParams,
                        selectedId: $selectedSkinParamId,
                        onRecover: { pendingRecover = .skin })
                    .opacity(selectedTab == .skin ? 1 : 0)
                    .allowsHitTesting(selectedTab == .skin)

                iconRow(params: BeautyParamCatalog.shapeParams,
                        selectedId: $selectedShapeParamId,
                        onRecover: { pendingRecover = .shape })
                    .opacity(selectedTab == .shape ? 1 : 0)
                    .allowsHitTesting(selectedTab == .shape)

                BeautyFilterPanel(store: store)
                    .opacity(selectedTab == .filter ? 1 : 0)
                    .allowsHitTesting(selectedTab == .filter)

                BeautyStickerPanel(store: store)
                    .opacity(selectedTab == .sticker ? 1 : 0)
                    .allowsHitTesting(selectedTab == .sticker)
            }
            .frame(height: 110)
        }
        .background(
            Color(hex: 0x2D1B4E).opacity(0.96)
                .clipShape(TopRoundedShape(radius: 20))
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var tabBar: some View {
        HStack(spacing: 24) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button { selectedTab = tab } label: {
                    Text(tab.label)
                        .font(.system(size: 17,
                                      weight: selectedTab == tab ? .bold : .regular))
                        .foregroundStyle(selectedTab == tab
                                         ? .white
                                         : Color.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private func iconRow(params: [BeautyParamEntry],
                         selectedId: Binding<String?>,
                         onRecover: @escaping () -> Void) -> some View {
        BeautyParamIconRow(params: params,
                           selectedParamId: selectedId,
                           onRecover: onRecover)
    }

    // MARK: - Recover: 重置本 tab 到 defaults

    private func resetSkin() {
        let d = BeautySettings.defaults
        store.mutate {
            $0.blur = d.blur; $0.whiten = d.whiten; $0.red = d.red
            $0.clarity = d.clarity; $0.sharpen = d.sharpen; $0.faceThreed = d.faceThreed
            $0.eyeBright = d.eyeBright; $0.toothWhiten = d.toothWhiten
            $0.removePouch = d.removePouch; $0.removeNasolabialFolds = d.removeNasolabialFolds
        }
    }

    private func resetShape() {
        let d = BeautySettings.defaults
        store.mutate {
            $0.cheekV = d.cheekV; $0.cheekNarrow = d.cheekNarrow
            $0.cheekShort = d.cheekShort; $0.cheekSmall = d.cheekSmall
            $0.intensityCheekbones = d.intensityCheekbones; $0.intensityLowerJaw = d.intensityLowerJaw
            $0.eyeEnlarging = d.eyeEnlarging; $0.intensityEyeCircle = d.intensityEyeCircle
            $0.intensityChin = d.intensityChin; $0.intensityForehead = d.intensityForehead
            $0.intensityNose = d.intensityNose; $0.intensityMouth = d.intensityMouth
            $0.intensityLipThick = d.intensityLipThick; $0.intensityCanthus = d.intensityCanthus
            $0.intensityEyeSpace = d.intensityEyeSpace
        }
    }
}

// MARK: - Top-rounded shape

private struct TopRoundedShape: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.maxY))
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: 0),
                          control: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: 0))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: radius),
                          control: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Previews

private struct BeautySettingsViewPreviewWrapper: View {
    let sharer: BeautyPipelineSharer
    var body: some View {
        NavigationStack { BeautySettingsView(sharer: sharer) }
    }
}

#Preview("默认档 H5 对齐") {
    BeautySettingsViewPreviewWrapper(
        sharer: BeautyPipelineSharer(persistence: InMemoryBeautyPersistence())
    )
}

#Preview("全关（enabled=false）") {
    let sharer = BeautyPipelineSharer(persistence: InMemoryBeautyPersistence())
    sharer.store.mutate { $0.enabled = false }
    return BeautySettingsViewPreviewWrapper(sharer: sharer)
}

#Preview("RTL - 阿拉伯语") {
    BeautySettingsViewPreviewWrapper(
        sharer: BeautyPipelineSharer(persistence: InMemoryBeautyPersistence())
    )
    .environment(\.layoutDirection, .rightToLeft)
}
