import SwiftUI

/// 用户详情页（H-0，对照 H5 `userProfile/index.vue`）。
///
/// 顶部 NavBar：返回（默认）+ FOLLOW/FOLLOWING 按钮 + ... 菜单。
/// 内容流：头像 + 昵称行 + uid + meta 行（country/age/connRate）+ like/favorite 双卡片 + 礼物墙占位 + 占位 ActionBar。
///
/// 接入：MainTabView .home case NavigationStack 注册 `navigationDestination(for: UserProfileRoute.self)`
/// → 各入口 `NavigationLink(value: UserProfileRoute.userId(...))` 推入此 View。
struct UserProfileView: View {
    @StateObject private var vm: UserProfileViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var showingMenu: Bool = false
    @State private var showingComingSoonToast: Bool = false
    /// 每次触发递增的 token，让 `.task(id:)` 自动取消上一次 sleep（review 建议-5）。
    @State private var comingSoonToken: Int = 0

    init(userId: String, service: UserProfileServiceProtocol? = nil) {
        let svc = service ?? UserProfileService.shared
        _vm = StateObject(wrappedValue: UserProfileViewModel(
            userId: userId,
            service: svc,
            isLiveProvider: { 0 },   // step 2 接 LiveStore.state == .living 派生
            networkErrorFallback: L10n.userProfileNetworkError,
            badUserIdFallback: L10n.userProfileBadUserId
        ))
    }

    var body: some View {
        ZStack {
            Theme.Palette.profileBackground.ignoresSafeArea()
            content
            transientErrorToast
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .enableSwipeBack()    // 自定义 leading 时保留左滑返回（trial #3 step 3 反悔 #8）
        .toolbar { toolbarContent }
        .toolbarBackground(Theme.Palette.profileBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
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
        // 菜单弹起
        .confirmationDialog("", isPresented: $showingMenu, titleVisibility: .hidden) {
            // 仅在 isBlocked != 1 + yxAccid 非 nil 时显示 Block 项（spec §1.4 / R-22）
            if vm.canShowBlockMenuItem {
                Button(L10n.userProfileMenuBlock, role: .destructive) {
                    vm.openBlockConfirm()
                }
            }
            Button(L10n.userProfileMenuReport, action: triggerComingSoonToast)
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
            if vm.detail != nil {
                followButton
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

                // like / favorite 卡片
                statsRow(detail: detail)
                    .padding(.horizontal, Theme.Metric.userProfileScreenHPadding)

                // 礼物墙（H5 gifts.vue：list 非空横向 grid 渲染；空 → 不显示整个区块）
                if !detail.giftList.isEmpty {
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
                // 消息：占位 toast（H 里程碑 IM 完善时接入）
                communicationButton(
                    systemImage: "bubble.left.fill",
                    a11yLabel: L10n.userProfileActionMessage,
                    action: triggerComingSoonToast
                )
                // 拨打：接 CallStore.shared.callOut（trial #3 step 3 反悔 #10）
                communicationButton(
                    systemImage: "phone.fill",
                    a11yLabel: L10n.userProfileActionCall,
                    action: { Task { await initiateCall(detail: detail) } }
                )
            }
        }
    }

    private func communicationButton(systemImage: String, a11yLabel: String,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Theme.Palette.userProfilePlaceholderBg)
                Image(systemName: systemImage)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11yLabel)
    }

    private func triggerComingSoonToast() {
        showingComingSoonToast = true
        comingSoonToken &+= 1   // 触发 .task(id:) 重启，自动 cancel 上次 sleep
    }

    // MARK: - 拨打通话（接入 CallStore，参 POCDebugView.dial 同款）

    @MainActor
    private func initiateCall(detail: UserDetail) async {
        // 守卫 1：RTM 信令未就绪
        guard CallStore.shared.isSignalingReady else {
            vm.transientError = L10n.userProfileNetworkError
            return
        }
        // 守卫 2：已在通话中
        guard CallStore.shared.state == .idle else {
            vm.transientError = CallStore.shared.lastError.isEmpty
                ? L10n.userProfileNetworkError
                : CallStore.shared.lastError
            return
        }
        // 拨打 —— 成功后 RootView 自动覆盖 CallView
        await CallStore.shared.callOut(remoteUserId: detail.userId)
        // 拨打瞬间失败（state 仍 .idle 且有 lastError）→ toast 提示
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
            // 头像（圆形）
            avatarImage(icon: detail.icon)
                .frame(width: Theme.Metric.userProfileAvatarSize,
                       height: Theme.Metric.userProfileAvatarSize)
                .clipShape(Circle())
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

    @ViewBuilder
    private func avatarImage(icon: String?) -> some View {
        if let s = icon, let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    avatarPlaceholder
                }
            }
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Theme.Palette.blocklistAvatarFallback
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundColor(.white.opacity(0.4))
                .padding(8)
        }
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
            if let cr = detail.connRate, !cr.isEmpty {
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
            if let n = iconName, UIImage(named: n) != nil {
                Image(n)
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
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFit()
                            default:                  giftIconPlaceholder
                            }
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
            if showingComingSoonToast {
                Text(L10n.commonComingSoon)
                    .font(Theme.Typography.blocklistToast)
                    .foregroundColor(.white)
                    .padding(.horizontal, Theme.Metric.blocklistToastHPadding)
                    .padding(.vertical, Theme.Metric.blocklistToastVPadding)
                    .background(Theme.Palette.blocklistToastBackground, in: Capsule())
                    .padding(.top, Theme.Metric.blocklistToastTopPadding)
                    .transition(.opacity)
                    .task(id: comingSoonToken) {
                        // .task(id:) 自动在新 token 到来 / view 消失时 cancel 上一轮（建议-5）
                        do {
                            try await Task.sleep(nanoseconds: 2_000_000_000)
                            try Task.checkCancellation()
                            showingComingSoonToast = false
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
            ]
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
