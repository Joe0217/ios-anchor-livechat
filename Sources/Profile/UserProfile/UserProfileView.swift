import SwiftUI

/// 用户详情页（H-0，对照 H5 `userProfile/index.vue`）。
///
/// 顶部 NavBar：返回（默认）+ FOLLOW/FOLLOWING 按钮 + ... 菜单。
/// 内容流：头像 + 昵称行 + uid + meta 行（country/age/connRate）+ like/favorite 双卡片 + 礼物墙占位 + 占位 ActionBar。
///
/// 接入：MainTabView .home case NavigationStack 注册 `navigationDestination(for: UserProfileRoute.self)`
/// → 各入口 `NavigationLink(value: UserProfileRoute.userId(...))` 推入此 View。
/// 消息按钮 push 私聊页：父 NavigationStack 需同时注册 `navigationDestination(for: String.self)`
/// → `ChatDetailContainer(peerYxAccId:, selfYxAccId:)`（home/work/LiveResult sheet 均已注册）。
struct UserProfileView: View {
    @StateObject private var vm: UserProfileViewModel
    @StateObject private var featureVM: UserProfileFeatureViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    /// 账户级权限（userType 黑名单）—— P 项目权限管理系统 UI 层订阅点。
    @ObservedObject private var permission = SelfPermissionBridge.shared
    @State private var showingMenu: Bool = false
    // Report sheet 显隐 + 成功 toast（对齐 H5 c-feedbackPopup 交互）
    @State private var showingReportSheet: Bool = false
    @State private var reportSuccessToast: Bool = false
    /// 每次触发递增的 token，让 `.task(id:)` 自动取消上一次 sleep（review 建议-5）。
    @State private var reportSuccessToken: Int = 0
    @State private var galleryContext: MediaGalleryContext?
    @State private var commentingPost: MomentPost?

    /// 若详情页是从私聊页 push 出来的，携带该私聊 peer 的 yxAccid。
    /// 「消息」按钮据此判断目标是否就是"上一层"—— 是则 pop 而非 push，避免详情↔聊天栈无限嵌套。
    private let originPeerYxAccId: String?

    init(userId: String, service: UserProfileServiceProtocol? = nil, originPeerYxAccId: String? = nil) {
        let svc = service ?? UserProfileService.shared
        _vm = StateObject(wrappedValue: UserProfileViewModel(
            userId: userId,
            service: svc,
            isLiveProvider: { 0 },   // step 2 接 LiveStore.state == .living 派生
            canFollowProvider: {
                SelfPermissionBridge.shared.canRelationshipActionsSnapshot
            },
            networkErrorFallback: L10n.userProfileNetworkError,
            badUserIdFallback: L10n.userProfileBadUserId
        ))
        _featureVM = StateObject(wrappedValue: UserProfileFeatureViewModel(userId: userId))
        self.originPeerYxAccId = originPeerYxAccId
    }

    var body: some View {
        ZStack(alignment: .top) {
            userProfilePageBackground.ignoresSafeArea()
            if let detail = vm.detail {
                levelCover(detail: detail)
                    .ignoresSafeArea(edges: .top)
            }
            if permission.canProfileViewing {
                content
            }
            transientErrorToast
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .enableSwipeBack()    // 自定义 leading 时保留左滑返回（trial #3 step 3 反悔 #8）
        .toolbar { toolbarContent }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .fullScreenCover(item: $galleryContext) { context in
            MediaGalleryView(urls: context.urls, startIndex: context.startIndex)
        }
        .task(id: permission.canProfileViewing) {
            guard permission.canProfileViewing else {
                showingMenu = false
                showingReportSheet = false
                return
            }
            // 首次进入触发拉取（idle / error 都可重拉，loading 中守护已在 VM 内）
            if case .loaded = vm.loadState { return }
            await vm.loadDetail()
        }
        .task(id: "\(permission.canVirtualItems)-\(permission.canProfileSocial)-\(vm.detail?.userId ?? "")") {
            guard (permission.canVirtualItems || permission.canProfileSocial), vm.detail != nil else { return }
            await featureVM.loadInitial(canVirtualItems: permission.canVirtualItems,
                                        canProfileSocial: permission.canProfileSocial)
        }
        .onChange(of: scenePhase) { newPhase in
            // 后台时关菜单 + popup（R-8）
            if newPhase != .active {
                showingMenu = false
                vm.cancelBlockConfirm()
            }
        }
        .onDisappear {
            // scenePhase 守卫：SwiftUI 在 .background 时也 onDisappear（v5.3.3 已知坑）
            guard scenePhase != .background else { return }
            vm.clearTransientError()
        }
        // 拉黑二次确认 popup
        .userProfileBlockConfirmDialog(vm: vm)
        // 举报 sheet（半屏，H5 van-popup position="bottom" 对齐）
        .sheet(isPresented: $showingReportSheet) {
            ReportUserSheet(
                userId: vm.userId,
                onSubmitSuccess: {
                    showingReportSheet = false
                    reportSuccessToast = true
                    reportSuccessToken &+= 1
                }
            )
            .giftPanelSheetBackground()
            .presentationDetents([.medium, .fraction(0.8)])
        }
        .sheet(item: $commentingPost) { post in
            MomentCommentComposer { content in
                guard let postId = post.postId else { return false }
                return await featureVM.submitMomentComment(postId: postId, content: content)
            }
            .presentationDetents([.height(160)])
            .presentationDragIndicator(.visible)
        }
        // 菜单弹起
        .confirmationDialog("", isPresented: $showingMenu, titleVisibility: .hidden) {
            // 仅在 isBlocked != 1 + yxAccid 非 nil 时显示 Block 项（spec §1.4 / R-22）
            if vm.canShowBlockMenuItem {
                Button(L10n.userProfileMenuBlock, role: .destructive) {
                    vm.openBlockConfirm()
                }
            }
            Button(L10n.userProfileMenuReport, role: .destructive) { showingReportSheet = true }
            Button(L10n.userProfileBlockConfirmCancel, role: .cancel) {}
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 自定义返回 chevron（隐藏默认 Back 文案，对齐 H5 CNavBar）
        ToolbarItem(placement: .topBarLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.commonBack)
        }
        // 不显示昵称在 NavBar（H5 行为，标题为空）
        ToolbarItem(placement: .topBarTrailing) {
            if permission.canProfileViewing, vm.detail != nil {
                HStack(spacing: 4) {
                    if permission.canRelationshipActions {
                        followButton
                    }
                    Button {
                        showingMenu = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.white)
                            .frame(width: 24, height: 32)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(L10n.userProfileA11yMenu)
                }
            }
        }
    }

    private var followButton: some View {
        Button {
            Task { await vm.toggleFollow() }
        } label: {
            HStack(spacing: Theme.Metric.userProfileFollowBtnIconGap) {
                if vm.detail?.followed != true {
                    CDNAssetImage("partyUserCardFollow")
                        .frame(width: 18, height: 18)
                }
                Text((vm.detail?.followed == true) ? L10n.userProfileFollowing : L10n.userProfileFollow)
                    .font(Theme.Typography.userProfileFollowBtn)
                    .foregroundColor(vm.detail?.followed == true ? .white : Theme.Palette.accentYellow)
            }
            .padding(.horizontal, Theme.Metric.userProfileFollowBtnHPadding)
            .padding(.vertical, Theme.Metric.userProfileFollowBtnVPadding)
            .background(followButtonBackground)
            .clipShape(Capsule())
            .opacity(vm.isFollowButtonDisabled ? Theme.Metric.blocklistButtonDisabledOpacity : 1.0)
        }
        .disabled(vm.isFollowButtonDisabled)
    }

    @ViewBuilder
    private var followButtonBackground: some View {
        if vm.detail?.followed == true {
            LinearGradient(
                colors: [
                    Theme.Palette.userProfileFollowGradientStart,
                    Theme.Palette.userProfileFollowGradientEnd
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            Color(red: 0x9E / 255, green: 0x7D / 255, blue: 0xDC / 255).opacity(0.9)
        }
    }

    // MARK: - Content 分支（按 loadState）

    @ViewBuilder
    private var content: some View {
        switch vm.loadState {
        case .idle, .loading:
            ProgressView()
                .tint(.white)
        case .loaded:
            if let detail = vm.detail {
                loadedContent(detail: detail)
            } else {
                // 不会发生：loaded + detail nil；防御性兜底
                EmptyView()
            }
        case .error(let msg):
            errorState(msg)
        }
    }

    private func loadedContent(detail: UserDetail) -> some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                // 头像行（左：头像三色环 + 右：消息/拨打 40x40 圆形按钮 — H5 line 160-171 布局）
                avatarRow(detail: detail)
                    .padding(.horizontal, Theme.Metric.userProfileScreenHPadding)
                    .padding(.top, Theme.Metric.userProfileHeaderVPadding)

                // 昵称 + gender icon
                nicknameRow(detail: detail)
                    .padding(.horizontal, Theme.Metric.userProfileScreenHPadding)

                // uid
                Text("\(L10n.userProfileUidPrefix)\(detail.userId)")
                    .font(Theme.Typography.userProfileUid)
                    .foregroundColor(Theme.Palette.userProfileUid)
                    .padding(.horizontal, Theme.Metric.userProfileScreenHPadding)
                    .padding(.top, Theme.Metric.userProfileUidTopMargin)
                    .padding(.bottom, Theme.Metric.userProfileUidBottomMargin)

                // meta 行 country + age + connRate
                metaRow(detail: detail)
                    .padding(.horizontal, Theme.Metric.userProfileScreenHPadding)
                    .padding(.bottom, Theme.Metric.userProfileMetaBottomMargin)

                // 关注相关统计属于社交能力；107 只保留基础资料和安全处置入口。
                if permission.canProfileSocial {
                    statsRow(detail: detail)
                        .padding(.horizontal, 12)
                }

                let photos = detail.picList.filter {
                    $0.mediaType == 1 && $0.vaild == 1 && !$0.mediaUrl.isEmpty
                }
                if permission.canProfileAlbum && !photos.isEmpty {
                    ProfileMediaGrid(
                        title: String(format: L10n.profilePhotosFormat, photos.count, photos.count),
                        items: photos.map {
                            MediaAsset(assetId: $0.assetId, url: $0.mediaUrl, coverUrl: nil,
                                       vaild: $0.vaild, createTime: nil)
                        },
                        isVideoGrid: false,
                        onTap: { item in
                            let urls = photos.map(\.mediaUrl)
                            if let index = urls.firstIndex(of: item.url ?? "") {
                                galleryContext = MediaGalleryContext(urls: urls, startIndex: index)
                            }
                        }
                    )
                    .padding(.top, Theme.Metric.userProfileSectionVTop)
                }

                // H5 guardian-card：直接消费 getUserDetail.guardianList 前三项，空态整卡隐藏。
                if permission.canVirtualItems, !detail.guardianList.isEmpty {
                    UserGuardianCard(guardians: detail.guardianList)
                        .padding(.horizontal, Theme.Metric.userProfileScreenHPadding)
                        .padding(.top, Theme.Metric.userProfileSectionVTop)
                }

                // H5 order is guardian -> honor -> gift wall.
                if permission.canVirtualItems {
                    honorWallSection
                        .padding(.horizontal, 12)
                        .padding(.top, Theme.Metric.userProfileSectionVTop)
                }

                // H5 gift wall has Lit / UnLit / All tabs and an independent endpoint.
                if permission.canVirtualItems {
                    giftWallSection
                        .padding(.horizontal, 12)
                        .padding(.top, Theme.Metric.userProfileSectionVTop)
                }

                // H5 hides the entire Moments block when the first page is empty.
                if permission.canProfileSocial, !featureVM.moments.isEmpty {
                    momentsSection
                        .padding(.top, Theme.Metric.userProfileSectionVTop)
                }

                Color.clear.frame(height: 32)
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func levelCover(detail: UserDetail) -> some View {
        if permission.canVirtualItems {
            let level = Int(detail.levelName ?? "") ?? 0
            let rangeStart = min(max(level / 10, 0), 10) * 10
            let url = URL(string: "https://file.lovetravel.link/mstatic/user-profile/lv-bg-\(rangeStart).webp")
            CachedAsyncImage(url: url, contentMode: .fill, persistent: true) {
                userProfilePageBackground
            }
            .frame(maxWidth: .infinity)
            .frame(height: 188)
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [Color.clear, userProfilePageBackground],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 80)
            }
            .clipped()
            .allowsHitTesting(false)
        }
    }

    private var userProfilePageBackground: Color {
        Color(hex: 0x3A2585)
    }

    // MARK: - 头像行（左头像 + 右消息/拨打 圆形按钮，对齐 H5 CCommunicationBtns 位置）

    private func avatarRow(detail: UserDetail) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            // 左：三色光环头像
            avatarSection(detail: detail)
            Spacer(minLength: 0)
            // 右：CommunicationBtns（H5 btn-size="h-40 w-40" 圆形）
            HStack(spacing: 12) {
                // 消息：push ChatDetailContainer（复用父 NavigationStack 已注册的
                // navigationDestination(for: String.self) —— 与 LiveResultView:328 同款）；
                // yxAccid 缺失时 disabled + 半透明视觉降级，不隐藏避免布局跳变
                if permission.canDirectMessages {
                    messageButton(detail: detail)
                }
                // 拨打：接 CallStore.shared.callOut（trial #3 step 3 反悔 #10）
                // P 项目：userType 黑名单命中时隐藏（三层防护 UI 层）
                if permission.canCall {
                    communicationButton(
                        assetName: "liveListVideoCall",
                        a11yLabel: L10n.userProfileActionCall,
                        action: { Task { await initiateCall(detail: detail) } }
                    )
                }
            }
        }
    }

    private func communicationButton(assetName: String, a11yLabel: String,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CDNAssetImage(assetName)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11yLabel)
    }

    @ViewBuilder
    private func messageButton(detail: UserDetail) -> some View {
        if let yx = detail.yxAccid, !yx.isEmpty {
            if yx == originPeerYxAccId {
                // 上一层就是这个私聊页 → pop 回去，避免栈无限嵌套（详见 UserProfileRoute.userIdFromChat 说明）
                Button {
                    dismiss()
                } label: {
                    CDNAssetImage("liveListChat").frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.userProfileActionMessage)
            } else {
                NavigationLink(value: ChatFromProfileRoute(peerYxAccId: yx, sourceUserId: vm.userId)) {
                    CDNAssetImage("liveListChat").frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.userProfileActionMessage)
            }
        } else {
            CDNAssetImage("liveListChat").frame(width: 40, height: 40)
                .opacity(Theme.Metric.blocklistButtonDisabledOpacity)
                .accessibilityLabel(L10n.userProfileActionMessage)
                .accessibilityAddTraits(.isButton)
        }
    }

    private func communicationButtonLabel(systemImage: String) -> some View {
        ZStack {
            Circle().fill(Theme.Palette.userProfilePlaceholderBg)
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .foregroundColor(.white)
        }
        .frame(width: 40, height: 40)
    }

    // MARK: - 拨打通话（接入 CallStore）

    /// code-review Finding 5：preflight (isSignalingReady + state==.idle) 已内部化到 CallStore.callOut，
    /// 失败会 set CallStore.lastError；此处只需调 callOut + observe lastError → vm.transientError。
    @MainActor
    private func initiateCall(detail: UserDetail) async {
        await CallStore.shared.callOut(remoteUserId: detail.userId)
        // 拨打瞬间失败（state 仍 .idle 且有 lastError）→ toast 提示（signaling 未就绪 / 通话中 / createCall 失败等）
        if CallStore.shared.state == .idle,
           !CallStore.shared.lastError.isEmpty {
            vm.transientError = CallStore.shared.lastError
        }
    }

    // MARK: - Avatar 三色光环

    private func avatarSection(detail: UserDetail) -> some View {
        ZStack {
            // 三色光环：3 圈 stroke 叠加
            avatarRing
            AvatarView(urlString: detail.icon,
                       size: Theme.Metric.userProfileAvatarSize,
                       kind: .user)
            if permission.canVirtualItems, let headFrame = detail.headFrame {
                HeadFrameView(urlString: headFrame, size: 108)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 108, height: 108)
        .accessibilityLabel(L10n.userProfileA11yAvatar)
    }

    private var avatarRing: some View {
        Circle()
            .stroke(
                AngularGradient(
                    colors: [
                        Theme.Palette.userProfileAvatarRing1,
                        Theme.Palette.userProfileAvatarRing2,
                        Theme.Palette.userProfileAvatarRing3,
                        Theme.Palette.userProfileAvatarRing1
                    ],
                    center: .center
                ),
                lineWidth: Theme.Metric.userProfileAvatarRingWidth
            )
            .frame(width: Theme.Metric.userProfileAvatarSize
                       + Theme.Metric.userProfileAvatarRingGap * 2,
                   height: Theme.Metric.userProfileAvatarSize
                       + Theme.Metric.userProfileAvatarRingGap * 2)
    }

    // MARK: - 昵称 + gender icon

    private func nicknameRow(detail: UserDetail) -> some View {
        HStack(spacing: Theme.Metric.userProfileNicknameToGenderGap) {
            Text(reviewSafeNickname(detail.nickname))
                .font(Theme.Typography.userProfileNickname)
                .foregroundColor(Theme.Palette.userProfileNickname)
            // gender icon（1=男 / 2=女 / 其他不显示）
            if let g = detail.gender {
                genderIcon(g)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Theme.Metric.userProfileHeaderVPadding)
    }

    private func reviewSafeNickname(_ value: String) -> String {
        let effectiveUserType = permission.effectiveUserTypeSnapshot
            ?? UserTypeExperience.effectiveUserType(userInfo: SessionStore.shared.user)
        return ObjectionableContentFilter.sanitizedForDisplay(
            value,
            replacement: "User",
            effectiveUserType: effectiveUserType
        )
    }

    @ViewBuilder
    private func genderIcon(_ gender: Int) -> some View {
        switch gender {
        case 1:
            // 男：蓝色♂
            Image(systemName: "person.fill")
                .font(.system(size: Theme.Metric.userProfileGenderIconHeight, weight: .semibold))
                .foregroundColor(Theme.Palette.userProfileAvatarRing1)
        case 2:
            // 女：粉色♀
            Image(systemName: "person.fill")
                .font(.system(size: Theme.Metric.userProfileGenderIconHeight, weight: .semibold))
                .foregroundColor(Theme.Palette.userProfileAvatarRing3)
        default:
            EmptyView()
        }
    }

    // MARK: - meta 行 country + age + connRate

    private func metaRow(detail: UserDetail) -> some View {
        HStack(spacing: 0) {
            // country
            metaItem(iconName: "profileLocationIcon",
                     sfFallback: "mappin.and.ellipse",
                     text: detail.countryId ?? "—")
            // age
            if let age = detail.age {
                Spacer().frame(width: Theme.Metric.userProfileMetaGroupGap)
                metaItem(iconName: "profileAgeIcon",
                         sfFallback: "calendar",
                         text: "\(age)")
            }
            // connRate
            if permission.canCall, let cr = detail.connRate, !cr.isEmpty {
                Spacer().frame(width: Theme.Metric.userProfileMetaGroupGap)
                metaItem(iconName: nil,
                         sfFallback: "video.fill",
                         text: cr)
            }
            Spacer(minLength: 0)
        }
    }

    private func metaItem(iconName: String?, sfFallback: String, text: String) -> some View {
        HStack(spacing: Theme.Metric.userProfileMetaIconTextGap) {
            if let n = iconName {
                CDNAssetImage(n)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Theme.Metric.userProfileMetaIconSize,
                           height: Theme.Metric.userProfileMetaIconSize)
            } else {
                Image(systemName: sfFallback)
                    .font(.system(size: Theme.Metric.userProfileMetaIconSize - 1))
                    .foregroundColor(Theme.Palette.userProfileNickname)
            }
            Text(text)
                .font(Theme.Typography.userProfileMeta)
                .foregroundColor(Theme.Palette.userProfileNickname)
        }
    }

    // MARK: - like / favorite 双卡片

    private func statsRow(detail: UserDetail) -> some View {
        HStack(spacing: Theme.Metric.userProfileStatsCardGap) {
            statsCard(sfIcon: "heart.fill",
                      tint: Theme.Palette.userProfileAvatarRing3,
                      value: detail.like,
                      label: L10n.userProfileLikeLabel)
            statsCard(sfIcon: "star.fill",
                      tint: .yellow,
                      value: detail.favorite,
                      label: L10n.userProfileFavoriteLabel)
        }
    }

    private func statsCard(sfIcon: String, tint: Color, value: Int, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: sfIcon)
                .font(.system(size: Theme.Metric.userProfileStatsIconSize, weight: .semibold))
                .foregroundColor(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(value, format: .number)
                    .font(Theme.Typography.userProfileStatsValue)
                    .foregroundColor(Theme.Palette.userProfileNickname)
                Text(label)
                    .font(Theme.Typography.userProfileStatsLabel)
                    .foregroundColor(Theme.Palette.userProfileStatsLabel)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Metric.userProfileStatsCardPadding)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.1))
        )
    }

    // MARK: - Honor wall

    private var honorWallSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            profileSectionHeader(icon: "icon-glory", title: L10n.userProfileHonorWallTitle)
            profileTabBar(UserPrivilegeType.allCases, selection: featureVM.privilegeType) { type in
                featureVM.selectPrivilegeType(type)
            } label: { type in
                switch type {
                case .badge: return L10n.userProfileHonorBadge
                case .frame: return L10n.userProfileHonorFrame
                case .vehicle: return L10n.userProfileHonorVehicle
                }
            }
            .padding(.horizontal, 12)
            honorWallBody.padding(.horizontal, 12)
        }
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var honorWallBody: some View {
        switch featureVM.privilegeState {
        case .idle, .loading:
            profileSectionProgress
        case .error:
            profileSectionEmpty(L10n.userProfileSectionLoadFailed)
        case .loaded:
            if featureVM.privilegeItems.isEmpty {
                profileSectionEmpty(L10n.userProfileHonorEmpty)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(featureVM.privilegeItems) { item in
                            privilegeCell(item)
                        }
                    }
                }
                .frame(height: 108)
            }
        }
    }

    private func privilegeCell(_ item: UserPrivilegeItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(item.obtained
                      ? LinearGradient(colors: [Color(red: 55/255, green: 19/255, blue: 67/255),
                                                Color(red: 137/255, green: 37/255, blue: 213/255)],
                                       startPoint: .leading, endPoint: .trailing)
                      : LinearGradient(colors: [Color.white.opacity(0.06)], startPoint: .leading, endPoint: .trailing))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(item.obtained ? Color.white : Color.clear, lineWidth: 0.5))
            VStack(spacing: 6) {
                CachedAsyncImage(url: item.imageURL.flatMap(URL.init(string:)), contentMode: .fit, persistent: true) {
                    Color.clear
                }
                .frame(width: 58, height: 58)
                .saturation(item.obtained ? 1 : 0)
                .opacity(item.obtained ? 1 : 0.45)
                if featureVM.privilegeType != .badge {
                    Text(item.name)
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(width: 66)
                }
            }
            if item.wearStatus == 1 {
                Text(L10n.userProfileHonorEquipped)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .frame(height: 18)
                    .background(LinearGradient(colors: [.orange, .pink, .purple], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if !item.obtained {
                    Image("UserProfileIconHonorLock")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(5)
            }
        }
        .frame(width: 76, height: 97)
    }

    // MARK: - Gift wall

    private var giftWallSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            profileSectionHeader(icon: "icon-gift-wall", title: L10n.userProfileGiftWallTitle)
            profileTabBar(UserGiftWallTab.allCases, selection: featureVM.giftTab) { tab in
                featureVM.selectGiftTab(tab)
            } label: { tab in
                switch tab {
                case .lit: return L10n.userProfileGiftLit
                case .unlit: return L10n.userProfileGiftUnlit
                case .all: return L10n.userProfileGiftAll
                }
            }
            .padding(.horizontal, 12)
            giftWallBody.padding(.horizontal, 12)
        }
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var giftWallBody: some View {
        switch featureVM.giftState {
        case .idle, .loading:
            profileSectionProgress
        case .error:
            profileSectionError(retry: featureVM.reloadGift)
        case .loaded:
            if featureVM.giftItems.isEmpty {
                profileSectionEmpty(giftEmptyText)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                        spacing: 6
                    ) {
                        ForEach(featureVM.giftItems) { gift in
                            giftCell(gift: gift)
                        }
                    }
                }
                .frame(height: 360)
            }
        }
    }

    private var giftEmptyText: String {
        switch featureVM.giftTab {
        case .lit: return L10n.userProfileGiftEmptyLit
        case .unlit: return L10n.userProfileGiftEmptyUnlit
        case .all: return L10n.userProfileGiftEmptyAll
        }
    }

    private func giftCell(gift: UserGiftWallItem) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                if let url = gift.iconURL.flatMap(URL.init(string:)) {
                    CachedAsyncImage(url: url, contentMode: .fit, persistent: true, cdn: (.gift, .fit)) {
                        giftIconPlaceholder
                    }
                } else {
                    giftIconPlaceholder
                }
                if gift.count > 0 {
                    Text("x\(gift.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .frame(height: 54)
            .saturation(gift.lit ? 1 : 0)
            .opacity(gift.lit ? 1 : 0.45)
            Text(gift.name)
                .font(.system(size: 11))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background {
            if gift.lit {
                LinearGradient(
                    colors: [Color(red: 55/255, green: 19/255, blue: 67/255),
                             Color(red: 137/255, green: 37/255, blue: 213/255)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Color.white.opacity(0.06)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(gift.lit ? Color.white : Color.clear, lineWidth: 0.5))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(gift.name.isEmpty ? L10n.userProfileA11yGiftFallback : gift.name), \(gift.count)")
    }

    private var giftIconPlaceholder: some View {
        ZStack {
            Theme.Palette.userProfilePlaceholderBg
            Image(systemName: "gift.fill")
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private func profileSectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 5) {
            Image(icon == "icon-glory" ? "UserProfileIconGlory" : "UserProfileIconGiftWall")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 15)
    }

    // MARK: - Moments

    private var momentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.userProfileMomentsTitle)
                .font(Theme.Typography.userProfileSection)
                .foregroundColor(.white)
                .padding(.horizontal, Theme.Metric.userProfileScreenHPadding)
            ForEach(featureVM.moments) { post in
                MomentPostRow(
                    post: post,
                    onLikeTap: post.postId.map { id in { featureVM.toggleMomentLike(postId: id) } },
                    onCommentTap: canComment(on: post) ? { commentingPost = post } : nil,
                    showComment: true,
                    onImageTap: { index in
                        guard let urls = post.imgUrls, !urls.isEmpty else { return }
                        galleryContext = MediaGalleryContext(urls: urls, startIndex: index)
                    },
                    translation: post.postId.flatMap { featureVM.momentTranslations[$0] },
                    onTapTranslate: translationAction(for: post),
                    isTranslating: post.postId.map { featureVM.translatingMomentIds.contains($0) } ?? false,
                    commentRefreshToken: post.postId.flatMap { featureVM.momentCommentRefreshTokens[$0] } ?? 0
                )
            }
        }
    }

    private func translationAction(for post: MomentPost) -> (() -> Void)? {
        guard let id = post.postId, let text = post.textContent, !text.isEmpty else { return nil }
        return { featureVM.translateMoment(postId: id, text: text) }
    }

    private func canComment(on post: MomentPost) -> Bool {
        if let mine = SessionStore.shared.user?.userId, post.userId == mine { return true }
        return (post.appId ?? 0) > 0
    }

    private func profileTabBar<Item: Identifiable & Equatable>(
        _ items: [Item],
        selection: Item,
        action: @escaping (Item) -> Void,
        label: @escaping (Item) -> String
    ) -> some View {
        HStack(spacing: 8) {
            ForEach(items) { item in
                Button { action(item) } label: {
                    Text(label(item))
                        .font(.system(size: 13, weight: item == selection ? .bold : .regular))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background {
                            if item == selection {
                                LinearGradient(colors: [Color(red: 236/255, green: 21/255, blue: 1),
                                                        Color(red: 170/255, green: 37/255, blue: 246/255)],
                                               startPoint: .leading, endPoint: .trailing)
                                    .clipShape(Capsule())
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var profileSectionProgress: some View {
        ProgressView().tint(.white).frame(maxWidth: .infinity).frame(height: 96)
    }

    private func profileSectionEmpty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.55))
            .frame(maxWidth: .infinity)
            .frame(height: 96)
    }

    private func profileSectionError(retry: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Text(L10n.userProfileSectionLoadFailed)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.55))
            Button(L10n.commonRetry, action: retry)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
    }


    // MARK: - error 态

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: Theme.Metric.blocklistErrorVStackSpacing) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: Theme.Metric.blocklistErrorIconSize))
                .foregroundStyle(.yellow.opacity(0.8))
            Text(msg)
                .font(Theme.Typography.blocklistEmpty)
                .foregroundColor(Theme.Palette.blocklistErrorMessage)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Metric.blocklistErrorTextHPadding)
            Button {
                Task { await vm.retry() }
            } label: {
                Text(L10n.userProfileLoadErrorRetry)
                    .font(Theme.Typography.blocklistToast)
                    .foregroundColor(Theme.Palette.blocklistRetryText)
                    .padding(.horizontal, Theme.Metric.blocklistRetryPaddingH)
                    .padding(.vertical, Theme.Metric.blocklistRetryPaddingV)
                    .background(Theme.Palette.blocklistRetryButton, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Transient error toast

    @ViewBuilder
    private var transientErrorToast: some View {
        VStack {
            if let msg = vm.transientError {
                Text(msg)
                    .font(Theme.Typography.blocklistToast)
                    .foregroundColor(.white)
                    .padding(.horizontal, Theme.Metric.blocklistToastHPadding)
                    .padding(.vertical, Theme.Metric.blocklistToastVPadding)
                    .background(Theme.Palette.blocklistToastBackground, in: Capsule())
                    .padding(.top, Theme.Metric.blocklistToastTopPadding)
                    .transition(.opacity)
                    .task(id: msg) {
                        do {
                            try await Task.sleep(nanoseconds: 2_000_000_000)
                            try Task.checkCancellation()
                            vm.clearTransientError()
                        } catch {
                            return
                        }
                    }
            }
            if reportSuccessToast {
                Text(L10n.reportSuccessToast)
                    .font(Theme.Typography.blocklistToast)
                    .foregroundColor(.white)
                    .padding(.horizontal, Theme.Metric.blocklistToastHPadding)
                    .padding(.vertical, Theme.Metric.blocklistToastVPadding)
                    .background(Theme.Palette.blocklistToastBackground, in: Capsule())
                    .padding(.top, Theme.Metric.blocklistToastTopPadding)
                    .transition(.opacity)
                    .task(id: reportSuccessToken) {
                        do {
                            try await Task.sleep(nanoseconds: 2_000_000_000)
                            try Task.checkCancellation()
                            reportSuccessToast = false
                        } catch {
                            return
                        }
                    }
            }
            Spacer()
        }
    }
}

private struct MomentCommentComposer: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var isSubmitting: Bool = false
    let onSubmit: (String) async -> Bool

    var body: some View {
        VStack(spacing: 14) {
            TextField(L10n.chatInputTypeMessage, text: $text, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit { submit() }
            HStack {
                Button(L10n.userProfileBlockConfirmCancel) { dismiss() }
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Button(action: submit) {
                    if isSubmitting {
                        ProgressView().tint(.white)
                    } else {
                        Text(L10n.chatInputSend)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .background(Theme.Palette.profileBackground.ignoresSafeArea())
    }

    private func submit() {
        guard !isSubmitting else { return }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        isSubmitting = true
        Task {
            let success = await onSubmit(content)
            isSubmitting = false
            if success { dismiss() }
        }
    }
}

// MARK: - 拉黑二次确认 dialog modifier

private extension View {
    func userProfileBlockConfirmDialog(vm: UserProfileViewModel) -> some View {
        self.confirmationDialog(
            L10n.userProfileBlockConfirmTitle,
            isPresented: Binding(
                get: { vm.showingBlockConfirm },
                set: { newVal in if !newVal { vm.cancelBlockConfirm() } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.userProfileBlockConfirmAction, role: .destructive) {
                Task { await vm.confirmBlock() }
            }
            Button(L10n.userProfileBlockConfirmCancel, role: .cancel) {
                vm.cancelBlockConfirm()
            }
        } message: {
            Text(L10n.userProfileBlockConfirmMessage)
        }
    }
}

// MARK: - Previews

#if DEBUG
private final class PreviewUserProfileService: UserProfileServiceProtocol {
    let detail: UserDetail
    let fetchError: Error?
    init(detail: UserDetail = .fixturePreview(),
         fetchError: Error? = nil) {
        self.detail = detail
        self.fetchError = fetchError
    }
    func fetchDetail(userId: Int) async throws -> UserDetail {
        if let e = fetchError { throw e }
        return detail
    }
    func follow(request: FollowUserRequest) async throws {}
    func block(request: BlockUserRequest) async throws {}
}

extension UserDetail {
    static func fixturePreview(followed: Bool = false, isBlocked: Int? = nil) -> UserDetail {
        UserDetail(
            userId: "100001", nickname: "Alice", icon: nil,
            gender: 2, age: 24, countryId: "United States", connRate: "85%",
            yxAccid: "yx_100001", followed: followed, isBlocked: isBlocked,
            like: 1234, favorite: 56,
            giftList: [
                Gift(giftId: 1, iconUrl: nil, name: "Rose", count: 12),
                Gift(giftId: 2, iconUrl: nil, name: "Heart", count: 5),
                Gift(giftId: 3, iconUrl: nil, name: "Diamond", count: 1)
            ],
            guardianList: [], picList: [], levelName: "38", headFrame: nil
        )
    }
}

#Preview("Loaded - 默认") {
    NavigationStack {
        UserProfileView(userId: "100001",
                        service: PreviewUserProfileService())
    }
    .preferredColorScheme(.dark)
}

#Preview("Loaded - Following") {
    NavigationStack {
        UserProfileView(userId: "100001",
                        service: PreviewUserProfileService(detail: .fixturePreview(followed: true)))
    }
    .preferredColorScheme(.dark)
}

#Preview("Loaded - 已拉黑") {
    NavigationStack {
        UserProfileView(userId: "100001",
                        service: PreviewUserProfileService(detail: .fixturePreview(isBlocked: 1)))
    }
    .preferredColorScheme(.dark)
}

#Preview("Error") {
    NavigationStack {
        UserProfileView(userId: "100001",
                        service: PreviewUserProfileService(fetchError: UserProfileServiceError.stubNotImplemented))
    }
    .preferredColorScheme(.dark)
}

#Preview("RTL 阿语") {
    NavigationStack {
        UserProfileView(userId: "100001",
                        service: PreviewUserProfileService())
    }
    .environment(\.layoutDirection, .rightToLeft)
    .preferredColorScheme(.dark)
}
#endif
