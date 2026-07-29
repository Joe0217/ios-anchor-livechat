import SwiftUI

/// 受限首屏"我的"tab:完整对齐 H5 [mineRestricted/index.vue](../../../anchor-livechat-h5/src/views/mineRestricted/index.vue)。
///
/// 布局(自上而下):
/// 1. 用户信息横向行:头像(tap Resubmit) + 昵称+ID + Edit 图标(tap Resubmit)
/// 2. Banner:审核态派生文案 + 3 档背景色
/// 3. Profile photos + Review video 两个 section:直接复用主界面 `ProfileMediaGrid`
/// 4. 顶部 Settings 入口 + 底部固定栏:审核未通过态显示 Resubmit 按钮 + WhatsApp 联系电话
///
/// **主题**:深色背景 `Theme.Palette.profileBackground` (#0B0010),对齐 H5 mineRestricted
/// `.registerBtnAndPhone { background: #0B0010 }` 同款暗色。
///
/// NavigationStack 承载 Register 4 步流程(与 LoginView 同 pattern,复用 RegisterPathHolder.shared)。
struct MineRestrictedView: View {
    @EnvironmentObject private var session: SessionStore
    @Binding var isOnSubpage: Bool
    @StateObject private var pathHolder = RegisterPathHolder.shared
    @StateObject private var registerStore = RegisterStore.shared
    @ObservedObject private var anchorStore = AnchorInfoStore.shared

    @State private var isResubmitLoading = false
    @State private var resubmitError: String?
    @State private var previewContext: MediaGalleryContext?
    /// H5 mineRestricted 使用固定客服电话，不在返回该页面时重复拉取全局配置。
    private let whatsappPhone = "+86 185 0202 7264"

    var body: some View {
        let _ = AppLogger.auth.info("[MineRestrictedView] body eval")
        return NavigationStack(path: $pathHolder.path) {
            content
                .navigationBarHidden(true)
                .navigationDestination(for: RegisterRoute.self) { route in
                    Group {
                        switch route {
                        case .basicInfo: RegisterBasicInfoView()
                        case .required: RegisterRequiredView()
                        case .videoRecord: RegisterVideoRecordView()
                        case .videoPreview: RegisterVideoPreviewView()
                        }
                    }
                    .environmentObject(registerStore)
                    .environmentObject(pathHolder)
                }
                .navigationDestination(for: ProfileRoute.self) { route in
                    switch route {
                    case .settings:     SettingsView(path: $pathHolder.path)
                    case .blocklist:    BlocklistView()
                    case .anchorPolicy: AnchorPolicyView()
                    case .language:     LanguageView()
                    case .feedback:     FeedbackView(path: $pathHolder.path)
                    case .levelDetail:  LevelDetailView()
                    case .dataStatistics: DataStatisticsView()
                    case .editProfile:  EditProfileView(service: EditProfileService.shared)
                    case .userAgreement:
                        H5WebContainerView(page: H5Page(url: URL(string: AppConfig.termsOfServiceURL)!, title: L10n.settingsTermsOfService))
                    case .privacyPolicy:
                        H5WebContainerView(page: H5Page(url: URL(string: AppConfig.privacyPolicyURL)!, title: L10n.settingsPrivacyPolicy))
                    }
                }
        }
        // 深色主题:profileBackground 是 #0B0010 深色,view 内所有 .primary/.secondary/.tertiary
        // 系统颜色必须在 dark colorScheme 下渲染成白色系,否则 light mode 用户看到黑字黑底(ProfileMediaGrid
        // 标题用 Theme.Palette.profileSection=Color.white,但 SwiftUI 系统颜色需靠 colorScheme 触发)。
        .preferredColorScheme(.dark)
        .onAppear(perform: syncTabBarVisibility)
        .onChange(of: pathHolder.path.isEmpty) { _ in syncTabBarVisibility() }
    }

    @ViewBuilder
    private var content: some View {
        // 2026-07-17 tap-fix v3(强制上溯):原 ZStack(alignment: .bottom) { ScrollView; bottomBar } 结构下,
        // bottomBar 的 `.background(Color.ignoresSafeArea(.bottom))` 让 ZStack 内 sibling Color 撑满整个 ZStack 边界,
        // **拦截 ScrollView 顶部 tap**(userInfoRow 头像 / edit / photos grid 全部无响应)。
        // 改用项目内标准 pattern `.safeAreaInset(edge: .bottom)` —— 与 ProfileView.swift:86 完全一致,
        // bottomBar 挂在 ScrollView safe area **外部**,不与内容 hit test 冲突。
        ScrollView {
            VStack(spacing: 16) {
                settingsRow
                userInfoRow
                RestrictedStatusBanner(user: session.user, variant: .mine)
                    .padding(.horizontal, 12)
                // 直接复用主界面 ProfileMediaGrid(与 ProfileView.contentForSelectedTab.album 同款)
                // 优点:Color.clear.aspectRatio(1) 骨架 + overlay CachedAsyncImage 避免图片错位;
                //      审核态蒙层(vaild=2 审核中 / 3 已拒)自动展示;视频角标 profileVideoPlay 已就位
                restrictedMediaCard(
                    title: "Profile photos",
                    items: anchorStore.photos,
                    isVideoGrid: false
                ) { asset in
                    openGallery(with: anchorStore.photos, target: asset)
                }
                restrictedMediaCard(
                    title: "Review video",
                    items: anchorStore.videos,
                    isVideoGrid: true
                ) { asset in
                    openGallery(with: anchorStore.videos, target: asset)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 16)   // 与 bottomBar 视觉呼吸
        }
        .background { restrictedBackground }
        // 2026-07-17 G1:下拉刷新(对齐 H5 CPullRefresh)——手动刷新审核态 + 资料
        // 对齐 list-refresh-preserve-items rule:refresh 期 UI 保留已展示 items(ProfileMediaGrid 内 items 不清空)
        .refreshable {
            await refreshRestricted()
        }
        // bottomBar 作为底部固定栏(挂 safeAreaInset,不干扰 ScrollView 内容 tap)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .fullScreenCover(item: $previewContext) { ctx in
            MediaGalleryView(urls: ctx.urls, startIndex: ctx.startIndex)
        }
    }

    // MARK: - 顶部设置与用户信息(对齐 H5)

    private var restrictedBackground: some View {
        VStack(spacing: 0) {
            Image("profileTopBg")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .clipped()
            Theme.Palette.profileBackground
        }
        .ignoresSafeArea(edges: .top)
    }

    private func syncTabBarVisibility() {
        isOnSubpage = !pathHolder.path.isEmpty
    }

    /// H5 `mineRestricted` 的 CCard：外侧 16pt，内部标题与网格 12pt。
    private func restrictedMediaCard(
        title: String,
        items: [MediaAsset],
        isVideoGrid: Bool,
        onTap: @escaping (MediaAsset) -> Void
    ) -> some View {
        ProfileMediaGrid(
            title: title,
            items: items,
            isVideoGrid: isVideoGrid,
            horizontalInset: 12,
            onTap: onTap
        )
        .padding(.vertical, 12)
        .background(Theme.Palette.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var settingsRow: some View {
        HStack {
            Spacer()
            Button {
                pathHolder.path.append(ProfileRoute.settings)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.profileSettings)
            .padding(.trailing, 8)
        }
        .frame(height: 44)
    }

    @ViewBuilder
    private var userInfoRow: some View {
        HStack(spacing: 10) {
            // 2026-07-17 tap-fix:头像 tap 用 Button + .plain 包装,label 加 contentShape(Circle) 明确热区。
            // 原 `.onTapGesture` 挂在 AvatarView 上,AvatarView 内部 avatarStack 已 clipShape(Circle) → 外部
            // gesture 与内部 clip 交互不稳定,SwiftUI arbitration 可能吞掉 tap。Button + contentShape 是显式且稳定的做法。
            Button(action: handleResubmit) {
                AvatarView(
                    urlString: session.user?.icon,
                    size: 80,
                    kind: .anchor,
                    disablesTap: true
                )
                .overlay(
                    Circle().stroke(Color(red: 0.55, green: 0.36, blue: 0.91), lineWidth: 3)
                )
                .contentShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                Text(session.user?.nickname ?? "")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)   // 防超长昵称挤压布局 push Edit 按钮出视图
                    .truncationMode(.tail)
                if !profileUserId.isEmpty {
                    Text("ID:\(profileUserId)")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 4)

            Spacer()

            Button(action: handleResubmit) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)   // 显式尺寸让热区可达 36x36(Apple HIG 最小 44x44,这里边界紧凑)
                    .contentShape(Rectangle())       // 按 rule swiftui-button-plain-hitarea.md,组合 label 必须显式定义热区
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - 底部固定栏(Resubmit + WhatsApp)

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 8) {
            if showResubmitButton {
                Button(action: handleResubmit) {
                    HStack(spacing: 8) {
                        if isResubmitLoading {
                            ProgressView().scaleEffect(0.85).tint(.white)
                        }
                        Text("Resubmit")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.52, green: 0.08, blue: 1.0),   // #8515FF
                                        Color(red: 0.89, green: 0.00, blue: 0.20)    // #E40132
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
                    .contentShape(Rectangle())   // 按 rule 让整个 button 区域(含 gradient background)可 tap
                }
                .buttonStyle(.plain)
                .disabled(isResubmitLoading)
                .padding(.horizontal, 25)
                .padding(.top, 10)
            }

            if let err = resubmitError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Button {
                UIPasteboard.general.string = whatsappPhone
                // 2026-07-17 R1:复制后 toast 反馈(对齐项目内 WorkSysInfoFooter 已有模式 + H5 van-haptics-feedback 语义)
                AppToastCenter.shared.show(L10n.commonCopySuccess)
            } label: {
                HStack(spacing: 4) {
                    Text("Contact us: whatsapp \(whatsappPhone)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.7))
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                .padding(10)
                .contentShape(Rectangle())   // 按 rule 让 padding 也是热区
            }
            .buttonStyle(.plain)
        }
        .background(
            // 挂 safeAreaInset 后,bottomBar 已在 safe area 外部;background 只画 view 内部,
            // 无需 ignoresSafeArea(否则会与 safeAreaInset 冲突导致 view 尺寸失控)
            Theme.Palette.profileBackground
                .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: -1)
        )
    }

    // MARK: - 派生态

    private var showResubmitButton: Bool {
        guard let u = session.user else { return false }
        // 审核未通过 = valid==1 && !onReview && type not in (2,9) && banAlways != true
        return u.valid == 1
            && u.onReview != true
            && u.banAlways != true
            && u.type != 2
            && u.type != 9
    }

    /// 使用资料 store 的原始字符串，避免 UI 对数字 ID 应用本地化分组格式。
    private var profileUserId: String {
        let storedId = anchorStore.userId
        if !storedId.isEmpty { return storedId }
        return session.user?.userId.map(String.init) ?? ""
    }

    // MARK: - 交互

    /// 受限“我的”下拉刷新仅同步审核态与资料，不重复请求固定客服电话配置。
    ///
    /// **注意**:`SessionStore.refreshAuditStatus` 内部已 `await AnchorInfoStore.shared.refresh()`
    /// (line 295),不再冗余并发调 `anchorStore.refresh()`(即使 refresh 内 inflightTask 短路合并,语义
    /// 不清晰易误导后续维护者)。
    private func refreshRestricted() async {
        await session.refreshAuditStatus()
    }

    /// 打开图库预览(与 ProfileView.openGallery 同款语义):
    /// 用 assetId 匹配起始 index,缺 id fallback URL 相等,仍缺从头开始
    private func openGallery(with items: [MediaAsset], target: MediaAsset) {
        let urls = items.compactMap { $0.url }
        guard !urls.isEmpty else { return }
        let idx: Int = {
            if let tid = target.assetId,
               let i = items.firstIndex(where: { $0.assetId == tid }) {
                return items[..<i].compactMap { $0.url }.count
            }
            if let tUrl = target.url,
               let i = urls.firstIndex(of: tUrl) {
                return i
            }
            return 0
        }()
        previewContext = MediaGalleryContext(urls: urls, startIndex: idx)
    }

    private func handleResubmit() {
        AppLogger.auth.info("[MineRestricted] open register from cached user info")
        guard !isResubmitLoading else {
            AppLogger.auth.notice("[MineRestricted] handleResubmit guarded: already loading")
            return
        }
        isResubmitLoading = true
        resubmitError = nil
        defer { isResubmitLoading = false }

        // H5 直接用已加载的 mineInfo 进入 register；这里同样不再额外请求资料接口。
        // 当前 info 是下拉/入页审核刷新后的最新快照，mine 与 LoginResult 是无网络回退。
        guard let mineInfo = cachedMineInfoForResubmit else {
            resubmitError = String(format: L10n.authErrorNetworkFormat, "user session invalid")
            return
        }
        let cachedPwd = KeychainStore.getString(for: KeychainKey.pendingRegisterPassword)
        registerStore.hydrate(from: mineInfo, cachedPassword: cachedPwd)
        pathHolder.path.append(RegisterRoute.basicInfo)
    }

    private var cachedMineInfoForResubmit: AnchorInfo? {
        if let info = anchorStore.info ?? anchorStore.mine { return info }
        return session.user.map(AnchorInfo.fromLoginResult)
    }
}
