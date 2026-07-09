import SwiftUI
import PhotosUI

/// H-2 私密媒体解锁页（Work → Gift Message）。
///
/// H5 视觉参考：`secretSettings/index.vue` — 两张 CCard（图片区 / 视频区），每张含缩略图网格 + "+" 按钮，
/// 底部固定 Submit 按钮，礼物选择通过 sheet 弹出。
struct GiftMessageView: View {
    @StateObject private var vm: GiftMessageStore
    /// 图片 PhotosPicker
    @State private var pickerImageItem: PhotosPickerItem?
    /// 视频 PhotosPicker
    @State private var pickerVideoItem: PhotosPickerItem?
    /// 依赖注入的 service（CommonGiftPanel `.imBind` factory 需要拉礼物列表）
    private let service: GiftMessageServiceProtocol
    /// submit 成功 → 对齐 H5 `router.back()` 立刻 pop 回退（step 3 反悔 #2 修复重复提交）
    @Environment(\.dismiss) private var dismiss
    /// scenePhase 守卫 —— onDisappear 里清 MediaGalleryCache 时排除切后台误触
    /// （swiftui-camera-preview.md §6：ScenePhase=.background 时 SwiftUI 也会调 onDisappear）
    @Environment(\.scenePhase) private var scenePhase
    /// tap 缩略图触发全屏预览（复用公共组件 [MediaGalleryView](../../Core/MediaGallery/MediaGalleryView.swift)；step 3 反悔 #12）
    /// 图片/视频组件层按 URL 扩展名自动区分，支持左右横滑；同类同库（图片 tap → 全图片库；视频 tap → 全视频库）
    @State private var galleryCtx: MediaGalleryContext?
    /// submit 成功 toast（step 3 反悔 #11 对齐 H5 `showToast('submit succeed'); router.back()`）
    /// 显示 1.2s 后 dismiss —— 用户在原页看到反馈，pop 动画期间 toast 被截断（H5 是新页显示，iOS 无跨页 toast 单例暂用原页短暂显）
    @State private var submitSuccessToast: String?

    init(userId: Int = 0,
         service: GiftMessageServiceProtocol? = nil,
         uploadService: PrivateMediaUploadServiceProtocol? = nil) {
        let svc = service ?? GiftMessageService.shared
        self.service = svc
        _vm = StateObject(wrappedValue: GiftMessageStore(
            userId: userId,
            service: svc,
            uploadService: uploadService ?? PrivateMediaUploadService.shared,
            networkErrorFallback: L10n.GiftMessage.networkErrorFallback,
            badFileFallback: L10n.GiftMessage.unsupportedFile,
            reachedLimitFallback: L10n.GiftMessage.reachedLimit,
            selectGiftRequiredFallback: L10n.GiftMessage.selectGiftRequired
        ))
    }

    var body: some View {
        ZStack {
            Theme.Palette.screenBackground.ignoresSafeArea()
            content
        }
        .navigationTitle(L10n.GiftMessage.navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Palette.screenBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            if case .idle = vm.loadState {
                await vm.loadAll()
            }
        }
        .safeAreaInset(edge: .bottom) {
            submitBar
        }
        // 图片 picker
        .photosPicker(isPresented: photoPresent, selection: $pickerImageItem, matching: .images)
        .onChange(of: pickerImageItem) { newItem in
            guard let newItem else { return }
            Task {
                do {
                    // /review 反悔 P1-5：do-catch 明确处理 loadTransferable 失败（iCloud 未下载 / 损坏文件），
                    // 而非 try? 吞错让用户点了 + 没反应
                    guard let data = try await newItem.loadTransferable(type: Data.self) else {
                        vm.transientError = L10n.GiftMessage.unsupportedFile
                        pickerImageItem = nil
                        return
                    }
                    await vm.uploadImage(data: data)
                } catch {
                    vm.transientError = L10n.GiftMessage.unsupportedFile
                }
                pickerImageItem = nil
            }
        }
        .photosPicker(isPresented: videoPresent, selection: $pickerVideoItem, matching: .videos)
        .onChange(of: pickerVideoItem) { newItem in
            guard let newItem else { return }
            Task {
                do {
                    // /review 反悔 P1-3：按 supportedContentTypes 判源格式，iPhone 相册视频多是 mov（QuickTime 容器），
                    // 硬编 .mp4 会让 OSS Content-Type 错配 → 其他端播放失败
                    let ext = newItem.supportedContentTypes.contains(.quickTimeMovie) ? "mov" : "mp4"
                    guard let data = try await newItem.loadTransferable(type: Data.self) else {
                        vm.transientError = L10n.GiftMessage.unsupportedFile
                        pickerVideoItem = nil
                        return
                    }
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("gm_\(UUID().uuidString).\(ext)")
                    // /review 反悔 P2-7：上传结束（success / fail）清理 tmp 避免累积占用
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    try data.write(to: tmp)
                    await vm.uploadVideo(fileURL: tmp)
                } catch {
                    vm.transientError = L10n.GiftMessage.unsupportedFile
                }
                pickerVideoItem = nil
            }
        }
        // H-4 迁移：IM 场景 → CommonGiftPanel（tabs=[.popular], footer=.instantSelect tap 即选中 + dismiss；未选择关闭 → onCancel）
        .sheet(isPresented: $vm.showingGiftPicker) {
            CommonGiftPanel(config: .imBind(
                service: service,
                onSelect: { vm.bindGift($0) },
                onCancel: { vm.cancelGiftBinding() }
            ))
            .sheetTopInset()
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .overlay(alignment: .top) { transientErrorToast }
        // 上传中全屏遮罩（对齐 H5 showLoadingToast forbidClick=true）
        .overlay { uploadingOverlay }
        // 提交成功 toast（居中显示 1.2s，dismiss 前用户可见）
        .overlay { submitSuccessToastView }
        // tap 缩略图 → 全屏预览（复用公共 MediaGalleryView：左右横滑 + 20MB LRU 池 + 视频/图片自动分流）
        .fullScreenCover(item: $galleryCtx) { ctx in
            MediaGalleryView(urls: ctx.urls, startIndex: ctx.startIndex)
        }
        // 页面 dismount 时清池释放（对齐 CircleView pattern：容器边界统一 clear）
        // scenePhase 守卫：切后台不误清（swiftui-camera-preview.md §6）
        .onDisappear {
            guard scenePhase != .background else { return }
            MediaGalleryCache.shared.clear()
        }
    }

    /// 上传中遮罩：半透明黑背景 + 转圈 + "Uploading..." 文案，屏蔽下方触摸（对齐 H5 forbidClick）
    @ViewBuilder
    private var uploadingOverlay: some View {
        if !vm.pendingUploadIds.isEmpty {
            ZStack {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}    // 拦截触摸（forbidClick）
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.4)
                    Text(L10n.GiftMessage.uploading)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.7))
                )
            }
            .transition(.opacity)
            .zIndex(2000)
            .accessibilityLabel(L10n.GiftMessage.uploading)
        }
    }

    /// 提交成功 toast：居中显示 1.2s，Submit 回调控制显现/dismiss 时序。
    /// **副作用防护**：期间加轻 dim + hitTesting 拦截 —— 防用户在 1.2s 窗口再点 Submit 触发重复提交
    /// （bug #1 回归防护：submit 后 imagesOriginal 未同步 + isSaving 已 defer=false → canSubmit=true 可再点）。
    @ViewBuilder
    private var submitSuccessToastView: some View {
        if let msg = submitSuccessToast {
            ZStack {
                Color.black.opacity(0.15)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}   // 拦截触摸

                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, .green)
                    Text(msg)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.75))
                )
            }
            .transition(.opacity)
            .zIndex(2100)
            .accessibilityLabel(msg)
        }
    }

    // MARK: - Photos picker binding derivers（用两个 @State 让 photosPicker 可分别触发）

    @State private var wantsPhotoPick: Bool = false
    @State private var wantsVideoPick: Bool = false
    private var photoPresent: Binding<Bool> {
        Binding(get: { wantsPhotoPick }, set: { wantsPhotoPick = $0 })
    }
    private var videoPresent: Binding<Bool> {
        Binding(get: { wantsVideoPick }, set: { wantsVideoPick = $0 })
    }

    // MARK: - Content 分支

    @ViewBuilder
    private var content: some View {
        switch vm.loadState {
        case .idle, .loading:
            ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            loadedContent
        case .error(let msg):
            errorState(msg)
        }
    }

    private var loadedContent: some View {
        ScrollView {
            VStack(spacing: 12) {
                mediaCard(
                    title: L10n.GiftMessage.photoTitle,
                    intro: L10n.GiftMessage.setGiftIntro,
                    count: vm.imagesEdit.count,
                    limit: vm.limit.privateNum,
                    countText: L10n.GiftMessage.photoCountFormat(vm.imagesEdit.count, vm.limit.privateNum),
                    items: vm.imagesEdit,
                    category: 1,
                    canAdd: vm.canAddImage,
                    onAdd: { wantsPhotoPick = true }
                )
                mediaCard(
                    title: L10n.GiftMessage.videoTitle,
                    intro: L10n.GiftMessage.setGiftIntro,
                    count: vm.videosEdit.count,
                    limit: vm.limit.privateVedioNum,
                    countText: L10n.GiftMessage.videoCountFormat(vm.videosEdit.count, vm.limit.privateVedioNum),
                    items: vm.videosEdit,
                    category: 2,
                    canAdd: vm.canAddVideo,
                    onAdd: { wantsVideoPick = true }
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func mediaCard(
        title: String,
        intro: String,
        count: Int,
        limit: Int,
        countText: String,
        items: [PrivateMedia],
        category: Int,
        canAdd: Bool,
        onAdd: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(title) \(countText)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }
            Text(intro)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))

            // 一行 3 列 + .flexible 平均分（对齐用户 step 3 反悔 #5）
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                      alignment: .leading, spacing: 16) {
                ForEach(items) { item in
                    PrivateMediaCard(
                        item: item,
                        onDelete: { vm.remove(itemId: item.id, category: category) },
                        onTap: {
                            // 同类库预览：图片 tap → 全图片；视频 tap → 全视频（signedUrl 优先，nil 兜底 originalUrl 让组件 .failed 层承接）
                            let sourceUrls = items.map { m in
                                m.isVideo ? (m.signedUrl ?? m.originalUrl) : m.originalUrl
                            }
                            let idx = items.firstIndex(where: { $0.id == item.id }) ?? 0
                            galleryCtx = MediaGalleryContext(urls: sourceUrls, startIndex: idx)
                        }
                    )
                }
                if canAdd {
                    addButton(action: onAdd)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: 0x2B213E).opacity(0.5))
        )
    }

    private func addButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4]))
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(.white.opacity(0.5))
            }
            .aspectRatio(1, contentMode: .fit)   // 与 PrivateMediaCard 尺寸对齐（一行 3 平均分）
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.GiftMessage.addMedia)
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.yellow.opacity(0.8))
            Text(msg)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                Task { await vm.retry() }
            } label: {
                Text(L10n.blocklistLoadErrorRetry)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Submit bar

    private var submitBar: some View {
        VStack(spacing: 0) {
            Button {
                Task {
                    let ok = await vm.submit()
                    if ok {
                        // 对齐 H5 `showToast('submit succeed'); router.back()`：先 toast 后 pop
                        submitSuccessToast = L10n.GiftMessage.submitSucceed
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        dismiss()
                    }
                }
            } label: {
                Text(L10n.GiftMessage.submit)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(vm.canSubmit
                                  ? LinearGradient(colors: [.pink, .purple], startPoint: .leading, endPoint: .trailing)
                                  : LinearGradient(colors: [.gray.opacity(0.5)], startPoint: .leading, endPoint: .trailing))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!vm.canSubmit)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.Palette.screenBackground)
    }

    // MARK: - Transient error toast

    @ViewBuilder
    private var transientErrorToast: some View {
        if let msg = vm.transientError {
            Text(msg)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.black.opacity(0.7), in: Capsule())
                .padding(.top, 8)
                .transition(.opacity)
                .task(id: msg) {
                    do {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        try Task.checkCancellation()
                        vm.clearTransientError()
                    } catch { return }
                }
        }
    }
}

#if DEBUG
#Preview("GiftMessageView") {
    NavigationStack {
        GiftMessageView()
    }
    .preferredColorScheme(.dark)
}
#endif
