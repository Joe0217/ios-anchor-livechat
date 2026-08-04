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
                SelfPermissionBridge.shared.canProfileSocialSnapshot
            },
            networkErrorFallback: L10n.userProfileNetworkError,
            badUserIdFallback: L10n.userProfileBadUserId
        ))
        self.originPeerYxAccId = originPeerYxAccId
    }

    var body: some View {
        ZStack {
            Theme.Palette.profileBackground.ignoresSafeArea()
            if permission.canProfileViewing {
                content
            }
            transientErrorToast
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .enableSwipeBack()    // 自定义 leading 时保留左滑返回（trial #3 step 3 反悔 #8）
        .toolbar { toolbarContent }
        .toolbarBackground(Theme.Palette.profileBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
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
        // 菜单弹起
        .confirmationDialog("", isPresented: $showingMenu, titleVisibility: .hidden) {
            // 仅在 isBlocked != 1 + yxAccid 非 nil 时显示 Block 项（spec §1.4 / R-22）
            if vm.canShowBlockMenuItem {
                Button(L10n.userProfileMenuBlock, role: .destructive) {
                    vm.openBlockConfirm()
                }
            }
            Button(L10n.userProfileMenuReport) { showingReportSheet = true }
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
        ToolbarItemGroup(placement: .topBarTrailing) {
            if permission.canProfileViewing, vm.detail != nil {
                if permission.canProfileSocial {
                    followButton
                }
                Button {
                    showingMenu = true
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.white)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.userProfileA11yMenu)
            }
        }
    }

    private var followButton: some View {
        Button {
            Task { await vm.toggleFollow() }
        } label: {
            HStack(spacing: Theme.Metric.userProfileFollowBtnIconGap) {
                Image(systemName: (vm.detail?.followed == true) ? "checkmark" : "plus")
                    .font(.system(size: Theme.Metric.userProfileFollowBtnIconSize - 2, weight: .bold))
                    .foregroundColor(.white)
                Text((vm.detail?.followed == true) ? L10n.userProfileFollowing : L10n.userProfileFollow)
                    .font(Theme.Typography.userProfileFollowBtn)
                    .foregroundColor(.white)
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
            Theme.Palette.userProfileFollowingButton
        } else {
            LinearGradient(
                colors: [
                    Theme.Palette.userProfileFollowGradientStart,
                    Theme.Palette.userProfileFollowGradientEnd
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
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
                        .padding(.horizontal, Theme.Metric.userProfileScreenHPadding)
                }

                // H5 guardian-card：直接消费 getUserDetail.guardianList 前三项，空态整卡隐藏。
                if permission.canVirtualItems, !detail.guardianList.isEmpty {
                    UserGuardianCard(guardians: detail.guardianList)
                        .padding(.horizontal, Theme.Metric.userProfileScreenHPadding)
                        .padding(.top, Theme.Metric.userProfileSectionVTop)
                }

                // 礼物墙（H5 gifts.vue：list 非空横向 grid 渲染；空 → 不显示整个区块）
                if permission.canVirtualItems, !detail.giftList.isEmpty {
                    giftWallSection(gifts: detail.giftList)
                        .padding(.horizontal, Theme.Metric.userProfileScreenHPadding)
                        .padding(.top, Theme.Metric.userProfileSectionVTop)
                }

                Color.clear.frame(height: 32)
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - 头像行（左头像 + 右消息/拨打 圆形按钮，对齐 H5 CCommunicationBtns 位置）

    private func avatarRow(detail: UserDetail) -> some View {
        HStack(alignment: .center, spacing: 0) {
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
                        systemImage: "phone.fill",
                        a11yLabel: L10n.userProfileActionCall,
                        action: { Task { await initiateCall(detail: detail) } }
                    )
                }
            }
        }
    }

    private func communicationButton(systemImage: String, a11yLabel: String,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            communicationButtonLabel(systemImage: systemImage)
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
                    communicationButtonLabel(systemImage: "bubble.left.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.userProfileActionMessage)
            } else {
                NavigationLink(value: ChatFromProfileRoute(peerYxAccId: yx, sourceUserId: vm.userId)) {
                    communicationButtonLabel(systemImage: "bubble.left.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.userProfileActionMessage)
            }
        } else {
            communicationButtonLabel(systemImage: "bubble.left.fill")
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
        }
        .frame(width: Theme.Metric.userProfileAvatarSize + 12,
               height: Theme.Metric.userProfileAvatarSize + 12)
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
            Text(detail.nickname)
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
        HStack(spacing: Theme.Metric.userProfileStatsIconToTextGap) {
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
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Metric.userProfileStatsCardPadding)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metric.userProfileStatsCardRadius, style: .continuous)
                .fill(Theme.Palette.userProfileStatsCardFill)
        )
    }

    // MARK: - 礼物墙（H5 gifts.vue 还原：横向 grid + 35x35 icon + name + xCount）

    private func giftWallSection(gifts: [Gift]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.userProfileGiftWallTitle)
                .font(Theme.Typography.userProfileSection)
                .foregroundColor(Theme.Palette.userProfileNickname)
            // 竖向 grid：固定每行 5 列（trial #3 step 3 反悔 #9）
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5),
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(gifts) { gift in
                    giftCell(gift: gift)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metric.userProfilePlaceholderRadius, style: .continuous)
                    .fill(Theme.Palette.userProfileStatsCardFill.opacity(0.5))   // H5 bg-[rgba(43,33,62,0.5)]
            )
        }
    }

    private func giftCell(gift: Gift) -> some View {
        VStack(spacing: 4) {
            // 礼物 icon（cell 宽随 column 自适应；icon 取 cell 宽 80% 让视觉放大）
            GeometryReader { proxy in
                let size = proxy.size.width * 0.8
                Group {
                    if let s = gift.iconUrl, let url = URL(string: s) {
                        CachedAsyncImage(url: url,
                                         contentMode: .fit,
                                         persistent: true,
                                         cdn: (.gift, .fit)) {
                            giftIconPlaceholder
                        }
                    } else {
                        giftIconPlaceholder
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .aspectRatio(1, contentMode: .fit)

            // 名称（H5 text-10 lh-12 white 50% truncate）
            Text(gift.name ?? "")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.Palette.userProfileUid)
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            // 数量 X N（H5 text-12 white font-500）
            Text("X \(gift.count)")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(gift.name ?? L10n.userProfileA11yGiftFallback), \(gift.count)")
    }

    private var giftIconPlaceholder: some View {
        ZStack {
            Theme.Palette.userProfilePlaceholderBg
            Image(systemName: "gift.fill")
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.4))
        }
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
            guardianList: []
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
