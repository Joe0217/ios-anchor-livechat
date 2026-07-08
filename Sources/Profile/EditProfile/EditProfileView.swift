import SwiftUI
import PhotosUI

/// 用户资料编辑主页（I-spec §7.1 / Step 1b）。
///
/// **结构**：NavigationStack + ScrollView + 5 section + 底部 Confirm；
/// **状态分流**：`.loading`/`.editing`/`.saving`/`.success`/`.loadError`/`.terminated`
///
/// - loading：全屏 ProgressView
/// - editing：正常编辑区
/// - saving：正常编辑区 + 上层 saving overlay（禁交互 + spinner）
/// - success：`.alert` 弹窗，用户点 Confirm → refresh + dismiss
/// - loadError：全屏 banner + Retry
/// - terminated：view 层立即 dismiss（session 挤下线，SessionStore 已 logout）
struct EditProfileView: View {
    // ⚠️ 必须 @StateObject 而非 @ObservedObject：
    // navigationDestination closure `case .editProfile: EditProfileView(service: ...)` 会被 SwiftUI
    // 反复求值。若外部每次 new EditProfileStore + View 用 @ObservedObject，store 无法保留生命周期
    // → phase 反复重置回 .loading → 用户看到 loading spinner 但 hydrate/refresh 已在旧 store 跑完
    // → 表现为"一直转圈 + 没有网络请求"。
    // @StateObject autoclosure 只在首次 body 求值时执行一次，保证 store 在 View 整个生命周期内唯一。
    @StateObject private var store: EditProfileStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// 生产入口：内部创建 store 并由 @StateObject 保留生命周期。
    init(service: EditProfileServiceProtocol) {
        _store = StateObject(wrappedValue: EditProfileStore(service: service))
    }

    #if DEBUG
    /// Preview 专用：注入已配好状态的 store（跳过 async fetch，直接展示各种态）
    init(previewStore: EditProfileStore) {
        _store = StateObject(wrappedValue: previewStore)
    }
    #endif

    @State private var showNicknameSheet: Bool = false
    /// 全屏媒体预览 context（复用私密照片公共组件 MediaGalleryView，支持多图横滑 + 20MB LRU 缓存 + 缩放/AVKit）
    /// 对齐 rule swiftui-fullscreencover-hoist.md：hoist 到 view 顶层唯一挂载点，禁止各 tile 自己挂
    /// 用户明示需求 2026-07-07：预览要"同步私密照片的公共组件"（GiftMessageView 已复用同款）
    @State private var galleryCtx: MediaGalleryContext?
    /// Discard confirm（未保存离开）；对齐 PostPublishView pattern（rule `swiftui-fullscreencover-hoist.md`）
    @State private var showDiscardConfirm: Bool = false

    var body: some View {
        content
            .background(Theme.Palette.screenBackground.ignoresSafeArea())
            .navigationTitle(L10n.EditProfile.navTitle)
            .navigationBarTitleDisplayMode(.inline)
            // 自定义 back：dirty 时拦截弹 discardConfirm（用户需求 2026-07-07 #2）
            // 隐藏系统 back 手势 back 无法拦截（iOS push 场景 API 限制），只能拦截 button
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        handleBackTap()
                    } label: {
                        // 视觉对齐系统 back
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.backward")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .disabled(store.phase == .saving)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.EditProfile.confirm) {
                        Task { await store.handleConfirm() }
                    }
                    .disabled(!store.canConfirm)
                    .fontWeight(.semibold)
                }
            }
        .task {
            // SWR 加载策略（2026-07-08 v2）：
            // 1. 优先 hydrate 用 AnchorInfoStore.info 秒开 4 基础字段
            //    （nickname/avatar/signature/greetMsgs），phase 直接进 .editing
            // 2. 命中缓存 → refreshInBackground 静默拉接口更新 review + 补齐 photos/videos/callVideo
            //    期间 View 加半透明 loading overlay 阻断交互，等接口回来才可编辑
            //    （用户需求 2026-07-08 v3：先显示旧信息+骨架作为上下文，但仍要等接口才能交互）
            // 3. 无缓存（冷启动 / 首次登录）→ 走原 load() 走 loading 分支
            //
            // Store 不引用 AnchorInfoStore.shared 单例（便于测试）；View 层负责传数据源。
            if case .loading = store.phase, store.originalSnapshot == .empty {
                if store.hydrate(from: AnchorInfoStore.shared.info) {
                    store.refreshInBackground()
                } else {
                    await store.load()
                }
            }
        }
        // 恢复系统左边缘右滑返回手势（.navigationBarBackButtonHidden(true) 默认会禁用它）
        // 用户需求 2026-07-08 v3：所有 push 页面默认支持左滑关闭
        .swipeToPopEnabled()
        .onDisappear {
            // 只在真正 dismiss 时清（切后台不清；对齐 rule swiftui-camera-preview onDisappear 精神）
            guard scenePhase != .background else { return }
            store.dispose()
            // 编辑页退出清全屏预览 LRU 缓存池（对齐 GiftMessageView pattern）
            MediaGalleryCache.shared.clear()
        }
        .onChange(of: store.phase) { newPhase in
            // 用户 session 挤下线 → 立即 dismiss（不弹 alert）
            if newPhase == .terminated {
                dismiss()
            }
        }
        .onChange(of: scenePhase) { newPhase in
            // spec §3.3 / N-34：切后台 uploading 超 60s 主动标 failed
            // saving 期间后台完成的 alert 由 successAlertBinding 天然延迟（SwiftUI 在 background 不 present alert）
            store.updateScenePhase(isActive: newPhase == .active)
        }
        .sheet(isPresented: $showNicknameSheet) {
            NicknameEditSheet(initial: store.draft.nickname) { newName in
                store.editNickname(newName)
            }
        }
        .alert(
            L10n.EditProfile.successDialogTitle,
            isPresented: successAlertBinding
        ) {
            Button(L10n.EditProfile.successDialogConfirm) {
                // 先 refresh 保证 Profile 页看到新数据（对齐 H5 back 后主页 onActivated 刷）
                // 再 acknowledgeSuccess → phase = .terminated → View onChange 自动 dismiss
                // 不在这里 dismiss()：让 phase 单一路径驱动 dismiss，避免 double dismiss + alert race
                Task {
                    await AnchorInfoStore.shared.refresh()
                    store.acknowledgeSuccess()
                }
            }
        }
        .overlay(alignment: .top) { toastOverlay }
        .fullScreenCover(item: $galleryCtx) { ctx in
            MediaGalleryView(urls: ctx.urls, startIndex: ctx.startIndex)
        }
        // Size alert（图片/视频超大 / 视频格式不支持 —— 醒目居中弹窗，替代顶部小 toast）
        // 用户需求 2026-07-07 #1：明显一点。对齐 vant showFailToast 中央大提示视觉意图
        .alert(
            L10n.EditProfile.sizeAlertTitle,
            isPresented: sizeAlertPresented,
            actions: {
                Button(L10n.EditProfile.sizeAlertOK, role: .cancel) {
                    store.clearTransientToast()
                }
            },
            message: {
                if let key = store.transientToast {
                    Text(Self.translate(key))
                }
            }
        )
        // Discard confirm（用户需求 2026-07-07 #2）：未保存离开 → 弹 confirmationDialog
        .confirmationDialog(
            L10n.EditProfile.discardTitle,
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.EditProfile.discardConfirm, role: .destructive) {
                dismiss()
            }
            Button(L10n.EditProfile.discardKeep, role: .cancel) { }
        } message: {
            Text(L10n.EditProfile.discardMessage)
        }
    }

    // MARK: - Content by phase

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .loading:
            loadingView
        case .loadError:
            loadErrorView
        case .editing, .saving, .success, .terminated:
            ZStack {
                editingScroll
                if store.phase == .saving {
                    savingOverlay
                } else if store.isRefreshing {
                    // SWR 期间半透明 loading overlay + 阻断交互（用户需求 2026-07-08 v3）
                    // 让用户看到 hydrate 出来的旧信息作为上下文，但等接口回来才能编辑；
                    // 避免用户在 review 态未就位时点了字段又要弹审核 toast 的怪异体验
                    swrLoadingOverlay
                }
            }
        }
    }

    // MARK: - Editing scroll

    private var editingScroll: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                basicSection
                photosSection
                videosSection
                callVideoSection
                greetMsgsSection
                Spacer(minLength: 24)
            }
            .padding(16)
        }
        // saving 中禁交互（已有）；SWR refresh 中也禁交互，等审核态+完整数据回来（用户需求 2026-07-08 v3）
        .allowsHitTesting(store.phase != .saving && !store.isRefreshing)
    }

    // MARK: - Sections

    private var basicSection: some View {
        EditProfileSectionCard(
            title: L10n.EditProfile.sectionBasicTitle,
            hint: L10n.EditProfile.sectionBasicHint
        ) {
            VStack(spacing: 16) {
                // 头像居中单独一行（NicknameEditRow 改为纵向双层，无需与 avatar 挤在同 HStack）
                HStack {
                    Spacer()
                    AvatarEditView(
                        avatarUrl: store.draft.avatarUrl,
                        isReviewing: store.review.avatar,
                        isRejected: store.review.avatarRejected,
                        onPick: { item in Task { await handleAvatarPicked(item) } },
                        onReviewingTap: {
                            store.showToast(.avatarInReview)
                        }
                    )
                    Spacer()
                }
                NicknameEditRow(
                    nickname: store.draft.nickname,
                    isReviewing: store.review.nickname,
                    onEdit: { showNicknameSheet = true },
                    onReviewingTap: {
                        store.showToast(.nicknameInReview)
                    }
                )
                Divider().background(Theme.Palette.divider)
                Text(L10n.EditProfile.bioLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                BioEditCard(
                    text: bioBinding,
                    isReviewing: store.review.signature
                )
            }
        }
    }

    private var photosSection: some View {
        EditProfileSectionCard(
            title: String(format: L10n.EditProfile.sectionPhotosTitleFormat, store.draft.photos.count)
        ) {
            PhotosEditGrid(
                items: store.draft.photos,
                isRefreshing: store.isRefreshing,
                onPick: { item in Task { await handlePhotoPicked(item) } },
                onRemove: { id in store.removePhoto(id: id) },
                onRetry: { id in store.retryPhoto(id: id) },
                onPreview: { tapped in presentGallery(items: store.draft.photos, tapped: tapped) }
            )
        }
    }

    private var videosSection: some View {
        EditProfileSectionCard(
            title: String(format: L10n.EditProfile.sectionVideosTitleFormat, store.draft.videos.count)
        ) {
            VideosEditGrid(
                items: store.draft.videos,
                isRefreshing: store.isRefreshing,
                onPick: { item in Task { await handleVideoPicked(item, forCallVideo: false) } },
                onRemove: { id in store.removeVideo(id: id) },
                onRetry: { id in store.retryVideo(id: id) },
                onPreview: { tapped in presentGallery(items: store.draft.videos, tapped: tapped) }
            )
        }
    }

    private var callVideoSection: some View {
        EditProfileSectionCard(
            title: L10n.EditProfile.sectionCallVideoTitle,
            hint: L10n.EditProfile.sectionCallVideoHint
        ) {
            CallVideoEditCell(
                item: store.draft.callVideo,
                isRefreshing: store.isRefreshing,
                onPick: { item in Task { await handleVideoPicked(item, forCallVideo: true) } },
                onRemove: { store.clearCallVideo() },
                onRetry: {
                    // 来电视频 retry：清空后重选
                    store.clearCallVideo()
                },
                onPreview: { tapped in presentGallery(items: [tapped], tapped: tapped) }
            )
        }
    }

    /// 从同类 grid 全组 items 构造 MediaGalleryContext，支持横滑切换（对齐 GiftMessageView pattern）
    /// - 排除 uploading/failed 态（这些 url 无效）；被拒图（vaild=3，本就 filter 掉）不在 draft 中
    /// - MediaGalleryView 自动按扩展名（.mp4/.mov）识别视频，无需 iOS 侧显式区分
    private func presentGallery(items: [DraftMediaItem], tapped: DraftMediaItem) {
        let previewable = items.filter { item in
            guard !item.url.isEmpty else { return false }
            if case .idle = item.uploadState { return true }
            return false
        }
        guard !previewable.isEmpty else { return }
        let urls = previewable.map(\.url)
        let idx = previewable.firstIndex(where: { $0.id == tapped.id }) ?? 0
        galleryCtx = MediaGalleryContext(urls: urls, startIndex: idx)
    }

    private var greetMsgsSection: some View {
        EditProfileSectionCard(
            title: L10n.EditProfile.sectionGreetMsgsTitle,
            hint: L10n.EditProfile.sectionGreetMsgsHint
        ) {
            GreetMsgEditSection(
                myMsgs: store.draft.greetMsgs,
                reviewingMsgs: store.review.reviewingGreetMsgs,
                onAdd: { content in store.addGreetMsg(content: content) },
                onRemove: { id in store.removeGreetMsg(id: id) }
            )
        }
    }

    // MARK: - Loading / Error / Saving overlays

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView().tint(.white)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadErrorView: some View {
        VStack(spacing: 16) {
            Spacer()
            Text(L10n.EditProfile.loadErrorTitle)
                .font(.system(size: 15))
                .foregroundStyle(Theme.Palette.textPrimary)
            if let msg = store.loadErrorMessage {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button(L10n.EditProfile.loadErrorRetry) {
                Task { await store.retry() }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Theme.Palette.brandOrange)
            .clipShape(Capsule())
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            ProgressView().tint(.white).scaleEffect(1.2)
        }
        .transition(.opacity)
    }

    /// SWR refresh 期间的 loading overlay（用户需求 2026-07-08 v3）
    ///
    /// 与 savingOverlay 区别：
    /// - saving 是"提交中"，用较深蒙层（0.35）+ 大 spinner 强调"数据在传输"
    /// - SWR refresh 是"数据加载中"，用较淡蒙层（0.2）+ 略小 spinner，让底下的 hydrate 旧数据仍隐约可见
    ///   —— 用户能看到"啊我是 Alice 有 X 张图"的上下文，但知道数据在完善
    private var swrLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            ProgressView().tint(.white).scaleEffect(1.1)
        }
        .transition(.opacity)
    }

    private var toastOverlay: some View {
        Group {
            // Critical case（size/format 相关）走 .alert，不重复顶部 toast，避免双弹（用户需求 #1）
            if let key = store.transientToast, !Self.isCriticalAlert(key) {
                Text(Self.translate(key))
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.75))
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .task(id: key) {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        store.clearTransientToast()
                    }
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Bindings

    private var successAlertBinding: Binding<Bool> {
        Binding(
            get: { store.phase == .success },
            set: { newValue in
                // set false：alert 关闭（用户点 button 或系统自动）→ 同步转 phase 避免下一帧
                // SwiftUI 检测 get() = true 再次 present 触发死循环（Step 3 反悔 #3-4 真根因）
                if !newValue { store.acknowledgeSuccess() }
            }
        )
    }

    private var bioBinding: Binding<String> {
        Binding(
            get: { store.draft.signature },
            set: { store.editSignature($0) }
        )
    }

    /// size/format alert binding —— transientToast 为 critical case 时 present
    private var sizeAlertPresented: Binding<Bool> {
        Binding(
            get: {
                if let key = store.transientToast { return Self.isCriticalAlert(key) }
                return false
            },
            set: { newValue in
                if !newValue { store.clearTransientToast() }
            }
        )
    }

    /// 判断 toast key 是否走 alert（醒目）而非 toast（普通）
    static func isCriticalAlert(_ key: EditProfileToastKey) -> Bool {
        switch key {
        case .imageTooLarge, .videoTooLarge, .videoFormatUnsupported:
            return true
        default:
            return false
        }
    }

    /// Back 按钮处理：dirty 时弹 discard confirm；非 dirty 直接 dismiss（用户需求 #2）
    private func handleBackTap() {
        // buildUpdateRequest != nil → 有变更需要 confirm；无变更直接 dismiss
        if store.buildUpdateRequest() != nil {
            showDiscardConfirm = true
        } else {
            dismiss()
        }
    }

    // MARK: - Media pick handlers（Step 1c 补真上传）

    private func handleAvatarPicked(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        await store.uploadAvatar(data: data)
    }

    private func handlePhotoPicked(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        await store.uploadPhoto(data: data)
    }

    private func handleVideoPicked(_ item: PhotosPickerItem, forCallVideo: Bool) async {
        // 视频用 loadTransferable(Movie.self) → URL，然后读 Data
        // Step 1c 补真上传接线（当前 Step 1b View 骨架已就位）
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        // 检验扩展名（从 PhotosPickerItem 拿不到扩展名，需 supportedContentTypes）
        let fileExtension = item.supportedContentTypes.first?.preferredFilenameExtension ?? "mp4"
        if forCallVideo {
            await store.uploadCallVideo(data: data, fileExtension: fileExtension)
        } else {
            await store.uploadVideo(data: data, fileExtension: fileExtension)
        }
    }

    // MARK: - Toast key → L10n 翻译

    static func translate(_ key: EditProfileToastKey) -> String {
        switch key {
        case .photosLimit:                return L10n.EditProfile.toastPhotosLimit
        case .videosLimit:                return L10n.EditProfile.toastVideosLimit
        case .uploading:                  return L10n.EditProfile.toastUploading
        case .uploadFailed:               return L10n.EditProfile.toastUploadFailed
        case .imageTooLarge:              return L10n.EditProfile.toastImageTooLarge
        case .videoTooLarge:              return L10n.EditProfile.toastVideoTooLarge
        case .videoFormatUnsupported:     return L10n.EditProfile.toastVideoFormatUnsupported
        case .avatarInReview:             return L10n.EditProfile.toastAvatarInReview
        case .nicknameInReview:           return L10n.EditProfile.toastNicknameInReview
        case .networkError:               return L10n.EditProfile.toastNetworkError
        case .uploadTimeout:              return L10n.EditProfile.toastUploadTimeout
        case .apiError(let code, let msg): return "\(msg) (\(code))"
        }
    }
}
