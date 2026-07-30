import ImageIO
import SwiftUI
import UIKit

/// 底部 4 tab 主壳。设计稿无原生 tab 栏样式（深色、无分隔线、激活态仅靠颜色区分），
/// 故用自定义 tab 栏 + safeAreaInset，使内容自动避让，不被遮挡。
///
/// 通用规则：tabbar 仅在 4 个 tab 根页显示；任何 push 入栈的子页（含未来新增）一律隐藏 tabbar。
/// 实现：所有一级 Tab 的 NavigationStack path 均上抬到本视图持有，由派生 Equatable
/// `SubpageSignal` 直接驱动 TabBar 的显示。只有当前 Tab 的 path 为空时才显示 TabBar。
/// 容器永驻视图层级（frame(height: 0) + clipped + opacity 0 + allowsHitTesting false），
/// 不做 if/EmptyView 增删——iOS 16 上几何坍缩比 view 增删的过渡动画更稳。
///
/// **Tab keep-alive 策略**：
/// - **Home / Messages**：用 ZStack + opacity 永久持有，view 树不被 dismantle —— 切走再回来时
///   `@StateObject`（朋友圈 feed / List segment / 滚动位置 / 网络请求缓存）全部保留
/// - **Work / Profile**：仍走 switch 销毁重建（用户接受重新加载）—— 避免长持栈占资源
///
/// 切 tab 行为：用户选择"切走回根"——`onChange(of: selection)` 触发即清空两 tab 的 path，
/// 切回时回到 tab 根页（与 Instagram 一致；NavigationStack 永久持有但 path 清空，所以视觉上
/// 仍回根页，而根页内 @StateObject 状态完整保留——朋友圈滚动位置不丢）。
///
/// scenePhase 守卫：CLAUDE.md v5.3.3 真根因坑——SwiftUI 在 `.background` 时仍触发 onChange，
/// 切后台时不要触发 withAnimation（回前台 backlog 会一次性闪烁），仅在 active/inactive 才动画。
struct MainTabView: View {
    private enum LiveEntryTarget {
        case home
        case work
    }

    @State private var selection: MainTab = .home
    /// P 项目权限管理：Party tab 按 userType 黑名单动态显隐（bit `.party` 命中 → 隐藏）。
    /// 本项目底 tab bar 是 ForEach + 自定义 Button（非 SwiftUI TabView），tab 数量变化不触发 tag 消失坑。
    @ObservedObject private var permission = SelfPermissionBridge.shared
    @State private var homePath: NavigationPath = NavigationPath()
    @State private var workPath: NavigationPath = NavigationPath()
    /// H-2 spec §4.1：Messages tab 加 NavigationStack path 支持 push ChatDetailView（对齐 homePath 模式）
    @State private var messagesPath: NavigationPath = NavigationPath()
    /// E-spec §0.2：Party tab 独立 NavigationPath（消除 v1 借宿 workPath 技术债）
    @State private var partyPath: NavigationPath = NavigationPath()
    @State private var profilePath: NavigationPath = NavigationPath()
    /// 最小化 Party 房点击开播时的二次确认目标；完整 Party 房仍维持原 toast 互斥。
    @State private var pendingLiveEntryTarget: LiveEntryTarget?
    /// 活动页 `GAME_TASK` 排行榜复用受信任的主播 H5 路由，避免降级到不包含任务奖励字段的原生通用榜。
    @State private var activityRankingPage: H5Page?
    @Environment(\.scenePhase) private var scenePhase

    /// `.starting` 期间锁 tabbar 拦截触摸，防止 push 到 LiveRoomView 前 tab 切换导致
    /// NavigationStack 销毁 → 后端已建房 iOS 无心跳/rtc = 僵尸房间（B-spec-开播设置页 §1.4 🔴#1 🔴#5）
    @ObservedObject private var liveSettingsLock = LiveSettingsLock.shared

    /// 程序驱动 tab 切换时抑制 `onChange(of: selection)` 清 path 逻辑。
    /// 场景：`liveResultTransitionAction` 从 Home 入口切 Work Tab 时同帧设 `workPath = [.liveResult]`；
    /// 若不抑制，`onChange(of: selection)` 会把 workPath 立即重置为 `NavigationPath()`，结果页 push 丢失。
    /// 生命周期：action 内 `true` → 下个 runloop `false`；只影响这一次程序驱动切换。
    @State private var suppressPathClearOnTabChange: Bool = false

    /// L 里程碑：匹配态摄像头会话（全局唯一 owner）。挂在 MainTabView 层让预览浮窗跨 tab 可见：
    /// - MatchTabView keep-alive 保护，但 overlay 挂 MatchTabView.overlay 时切走 tab 就消失
    /// - 提升到 MainTabView 后 overlay 在 tab 切换外仍可见；session 唯一实例，attach 一次
    @StateObject private var matchCameraSession = MatchCameraSession()
    /// L 里程碑：观察 MatchStore.state 决定浮窗显示；MatchStore.shared 5 个 @Published，
    /// 但 MainTabView body 本身不高频重算（tab 切换/subpage 才触发），性能可接受（review S-4 同源）
    @ObservedObject private var matchStore = MatchStore.shared

    /// L 里程碑 #3c：10 分钟提示弹窗调度器（跨 tab 全局）
    @ObservedObject private var matchPopupCoordinator = MatchPopupCoordinator.shared
    /// Party 小窗的窄观察源，避免主壳订阅 PartyStore 的高频麦位/公屏更新。
    @ObservedObject private var minimizedParty = PartyStore.shared.minimizedBridge

    /// 直播结束页 back 时切 Work Tab + 清 Home/Work path。
    /// 两 path 都清：Home QuickGoLive 与 Work Go Live 两个入口都可能把 LiveSettings/LiveRoomView
    /// 塞进对应 path，切 tab 到 Work 时若不清对方 path，用户回到起始入口 tab 仍能 back 回残留 view。
    /// LiveRoomView 随 path 清空自然 dismantle → onDisappear 清相机/RTC/NIM/心跳。
    private var liveTerminationAction: LiveTerminationAction {
        LiveTerminationAction {
            // LiveStore 非单例（LiveRoomView @StateObject），随 view dismount 自然释放；
            // 下一场开播由 attachLiving 重置 begin/endTimestamp/endType，无需外层显式 reset
            selection = .work
            homePath = NavigationPath()
            workPath = NavigationPath()
        }
    }

    /// Work Match 图标点击 → 切 Home Tab + 请求 LiveTabView 切 Match top tab（对齐首页 Match 入口）。
    private var openHomeMatchAction: OpenHomeMatchAction {
        OpenHomeMatchAction {
            selection = .home
            HomeNavigationBus.shared.requestTopTab(.match)
        }
    }

    /// 跨 tab 打开私聊页 action：切 Messages Tab + 清 home/work path + push peerYxAccId 到 messagesPath。
    /// 从直播结果页 Message 按钮触发时，LiveRoomView 已随 state=.ended 主动清资源；path 清空后 dismount 幂等兜底。
    ///
    /// **必须抑制 onChange(of: selection) 清 path**（对齐 `liveResultTransitionAction`）：
    /// `selection = .messages` 会触发 onChange 把 messagesPath 立即重置为 NavigationPath()，
    /// 覆盖同帧刚设置的 `[peerYxAccId]` → Messages Tab 只显示会话列表根页，push 丢失。
    private var openChatAction: OpenChatAction {
        OpenChatAction { peerYxAccId in
            guard !peerYxAccId.isEmpty else { return }
            suppressPathClearOnTabChange = true
            selection = .messages
            homePath = NavigationPath()
            workPath = NavigationPath()
            messagesPath = NavigationPath([peerYxAccId])
            DispatchQueue.main.async { suppressPathClearOnTabChange = false }
        }
    }

    /// 跨 view 打开用户详情页 action:append UserProfileRoute 到**当前活跃 tab** 的 path。
    /// 用于 ChatDetailView 里系统消息 tap "ID 12345" 场景 —— openURL 回调无法用 NavigationLink 承载 push。
    /// 已注册的各 tab navigationDestination(for: UserProfileRoute.self) 会自动接单。
    private var openUserProfileAction: OpenUserProfileAction {
        OpenUserProfileAction { userId in
            let route = UserProfileRoute.userId(userId)
            switch selection {
            case .home:     homePath.append(route)
            case .messages: messagesPath.append(route)
            case .work:     workPath.append(route)
            case .party:    partyPath.append(route)
            case .profile:  profilePath.append(route)
            }
        }
    }

    /// 直播结束 → 切 Work Tab + workPath 重建为单层 `[liveResult]`（B spec v7 push 架构）。
    /// LiveRoomView + LiveSettings dismount 触发 onDisappear 正常清资源；结果页作为新根出现。
    ///
    /// **必须抑制 onChange(of: selection) 清 path**（review 202607091438 P1）：
    /// 从 Home 入口开播时 selection 从 .home → .work 会触发 onChange 清 workPath，
    /// 把我们刚设的 `[liveResult]` 立即覆盖为空 → 结果页无法显示。
    private var liveResultTransitionAction: LiveResultTransitionAction {
        LiveResultTransitionAction { begin, end, endType in
            guard let begin, let end else {
                // 时间戳缺失（异常路径）：不构造 route，直接切 Work 根
                suppressPathClearOnTabChange = true
                selection = .work
                homePath = NavigationPath()
                workPath = NavigationPath()
                DispatchQueue.main.async { suppressPathClearOnTabChange = false }
                return
            }
            suppressPathClearOnTabChange = true
            selection = .work
            homePath = NavigationPath()
            workPath = NavigationPath([WorkRoute.liveResult(begin: begin, end: end, endType: endType)])
            DispatchQueue.main.async { suppressPathClearOnTabChange = false }
        }
    }

    /// 派生信号：当前选中 tab 是否在子页（对应 tab 的 path 非空）。
    /// 用单一 Equatable 信号触发 onChange，避免 selection / workPath.count / profilePath.count
    /// 三个独立 onChange 在同一 transaction 内互相 reentrancy 导致动画闪烁。
    private var isOnSubpageSignal: Bool {
        switch selection {
        case .home:     return !homePath.isEmpty    // H-0：用户详情页等多入口共享 UserProfileRoute
        case .work:     return !workPath.isEmpty
        case .messages: return !messagesPath.isEmpty   // H-2：私聊页 push 后隐藏 tabbar 避免遮挡输入栏
        case .party:    return !partyPath.isEmpty   // E-spec：Party tab push PartyRoomView / PartyCreateRoomView 时隐藏 tabbar
        case .profile:  return !profilePath.isEmpty
        }
    }

    var body: some View {
        ZStack {
            Theme.Palette.screenBackground.ignoresSafeArea()
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            tabBarHostContainer
        }
        .alert(
            L10n.Party.alertTitle,
            isPresented: Binding(
                get: { pendingLiveEntryTarget != nil },
                set: { if !$0 { pendingLiveEntryTarget = nil } }
            )
        ) {
            Button(L10n.Party.cancel, role: .cancel) {
                pendingLiveEntryTarget = nil
            }
            Button(L10n.Party.ok) {
                confirmLiveEntryAfterLeavingMinimizedParty()
            }
        } message: {
            Text(L10n.Party.mutexBlockedByParty)
        }
        .fullScreenCover(item: $activityRankingPage) { page in
            H5WebSheetView(page: page)
                .ignoresSafeArea()
        }
        .onChange(of: isOnSubpageSignal) { newValue in
            InviteMessageCenter.shared.updateDisplayContext(isAtRootPage: !newValue)
            RobotCallRouteGate.shared.update(isAtRootPage: !newValue)
            // L 里程碑：子页拦截 tip 弹窗（对齐 H5 c-goMatch 仅挂 home 页面语义 —— 直播间/详情页/开播设置等均不弹）
            // 通话态由 RootView.CallView zIndex 100 全屏覆盖，tip zIndex 50 视觉上已被盖，无需额外 gate
            matchPopupCoordinator.updateBlockedByOtherPage(newValue)
        }
        .onChange(of: selection) { newValue in
            InviteMessageCenter.shared.updateDisplayContext(isAtRootPage: !isOnSubpageSignal)
            // 程序驱动切换（如 liveResultTransition 结束直播切 Work + 重建 workPath 为 [.liveResult]）
            // 必须跳过清 path，避免覆盖 action 内同帧刚设置的路径（review 202607091438 P1）
            guard !suppressPathClearOnTabChange else { return }
            // 切走 tab 立即清空各 tab 的 path，切回时回到根页
            homePath = NavigationPath()
            workPath = NavigationPath()
            messagesPath = NavigationPath()   // H-2：Messages tab 切走时也回根页
            partyPath = NavigationPath()      // E-spec：Party tab 同款清 path
            profilePath = NavigationPath()
            // E-spec §0.2 F-16：Party 主 tab gate（大厅根页 + 子页都抑制 match tip 弹窗）
            matchPopupCoordinator.updatePartyTabBlocked(newValue == .party)
        }
        .onReceive(NotificationCenter.default.publisher(for: .inviteChatRequested)) { notification in
            guard let yxAccid = notification.userInfo?["yxAccid"] as? String,
                  !yxAccid.isEmpty else { return }
            openChatAction.perform(yxAccid)
        }
        .onReceive(H5NativeActionRouter.shared.publisher) { destination in
            handleH5NativeDestination(destination)
        }
        .task {
            // 全局图片配置预热（对齐 H5 app.js `getBannerList([2])`）：
            // 首页 banner 位靠此接口喂数据；J 里程碑接入启动图/挂件/榜单/分类贴图时按需扩 types
            await AppPictureStore.shared.loadIfNeeded(types: [.banner])
        }
        .task {
            // 跑马灯预热（对齐 H5 `getLiveMarqueeListData()` 进 Live 广场就调）——
            // 独立 .task 让两个预热并发起飞（一起 await 也可以；分开更直观）
            await GiftMarqueeStore.shared.loadIfNeeded()
        }
        .onAppear {
            InviteMessageCenter.shared.updateDisplayContext(isAtRootPage: !isOnSubpageSignal)
            RobotCallRouteGate.shared.update(isAtRootPage: !isOnSubpageSignal)
            // L 里程碑：一次性 attach 全局匹配摄像头会话到 MatchStore.shared
            MatchStore.shared.attachCameraSession(matchCameraSession)
            // L 里程碑 #3c：启动 10 分钟提示弹窗调度
            matchPopupCoordinator.start()
            // E-spec §0.2 F-16：初始 gate 同步（onChange 不触发首次；覆盖冷启动 selection != .home 的场景）
            matchPopupCoordinator.updatePartyTabBlocked(selection == .party)
            // P 项目权限管理：冷启动 selection == .party 但 permission.canParty == false 时兜底
            if selection == .party && !permission.canParty {
                partyPath = NavigationPath()
                selection = .home
            }
        }
        // 观察 scenePhase 更新 popupCoordinator.appHidden 用于组合态 gate
        .onChange(of: scenePhase) { newPhase in
            matchPopupCoordinator.updateAppHidden(newPhase != .active)
        }
        .onDisappear {
            RobotCallRouteGate.shared.update(isAtRootPage: false)
        }
        // Party 权限撤销时，无论用户当前停在哪个 tab，都必须结束可能最小化在后台的 Party 会话。
        .onChange(of: permission.canParty) { newValue in
            if !newValue {
                partyPath = NavigationPath()
                if selection == .party {
                    selection = .home
                }
                Task { await PartyStore.shared.forceLeaveRoom(.userRequest) }
            }
        }
        // L 里程碑：全局匹配预览浮窗（跨 tab 展示）
        // .overlay 挂在 safeAreaInset 之后 → 覆盖全屏（含 tabbar 区域）
        .overlay {
            if matchStore.state == .matching {
                MatchCameraPreviewFloating(
                    camera: matchCameraSession.camera,
                    onClose: {
                        Task { @MainActor in
                            await MatchStore.shared.closeMatch()
                        }
                    }
                )
                .transition(.opacity)
                .accessibilityLabel(L10n.matchMarqueeCallStarted)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: matchStore.state == .matching)
        // Party 小窗：仅房间页面被最小化，RTC/NIM 仍由 PartyStore 持有。主壳负责跨 tab 的恢复与退出入口。
        .overlay {
            if minimizedParty.isVisible {
                PartyRoomFloatingBubble(
                    avatarURL: minimizedParty.roomAvatarURL,
                    onRestore: restoreMinimizedPartyRoom,
                    onLeave: leaveMinimizedPartyRoom
                )
                .transition(.opacity)
                .zIndex(70)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: minimizedParty.isVisible)
        // L 里程碑 #3c：10 分钟提示弹窗（全局跨 tab）
        .overlay {
            if matchPopupCoordinator.isShowing {
                MatchTipPopup(
                    onGoMatch: { noReminder in
                        if noReminder {
                            matchPopupCoordinator.markTodayNoReminder()
                        } else {
                            matchPopupCoordinator.dismiss()
                        }
                        Task { @MainActor in
                            if MatchStore.shared.isFirstMatchToday {
                                // 首日走规则弹窗（CGoMatchButton 内挂载；这里不重复启动）
                                // 直接切到 Match tab + tip dismiss，等用户主动点开关
                            } else {
                                await MatchStore.shared.openMatch()
                            }
                        }
                    },
                    onClose: { noReminder in
                        if noReminder {
                            matchPopupCoordinator.markTodayNoReminder()
                        } else {
                            matchPopupCoordinator.dismiss()
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(50)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: matchPopupCoordinator.isShowing)
        // L 里程碑 #3d：未露脸倒计时弹窗（.matching 期间人脸检测未检出触发）
        .overlay {
            if matchStore.showNoFacePopup {
                MatchNoFacePopup(onDismiss: { matchStore.dismissNoFacePopup() })
                    .transition(.opacity)
                    .zIndex(60)
            }
        }
        // L 里程碑 #3d：移除匹配弹窗（未露脸倒计时结束 → 已 blocked → 展示确认）
        .overlay {
            if matchStore.showExitMatchPopup {
                MatchExitPopup(onOK: { matchStore.dismissExitMatchPopup() })
                    .transition(.opacity)
                    .zIndex(60)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: matchStore.showNoFacePopup)
        .animation(.easeInOut(duration: 0.2), value: matchStore.showExitMatchPopup)
        // Match toast 全局展示：沿用项目通用 toast 视觉和时长。
        .overlay(alignment: .top) {
            if let toast = matchStore.lastToast {
                Text(toast.localized)
                    .toastStyle()
                    .transition(Toast.transition)
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: Toast.dismissDurationNanos)
                        matchStore.clearLastToast()
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: matchStore.lastToast)
        // L Gap-5：非匹配来电接通后挂断的"是否恢复匹配"确认 Alert（跨 tab 全局）
        .alert(
            L10n.matchResumeAlertTitle,
            isPresented: Binding(
                get: { matchStore.showResumeMatchAlert },
                set: { if !$0 { matchStore.dismissResumeMatchAlert() } }
            )
        ) {
            Button(L10n.matchResumeAlertConfirm) { matchStore.confirmResumeMatch() }
            Button(L10n.matchResumeAlertCancel, role: .cancel) { matchStore.dismissResumeMatchAlert() }
        } message: {
            Text(L10n.matchResumeAlertMessage)
        }
        .preferredColorScheme(.dark)
    }

    /// content 分两层：
    /// 1. ZStack 永久持有 Home / Messages（opacity 切显隐，view 树不 dismantle）
    /// 2. 内嵌 if 切换 Work / Profile（销毁重建，资源不长持）
    private var content: some View {
        ZStack {
            // —— Home：永久持有 ——
            // H-0：home tab 加 NavigationStack 支持多入口 UserProfileRoute（spec §5.3）。
            // 未来兄弟入口（Circle 头像 / Live 主播头像）也通过 NavigationLink(value: UserProfileRoute.userId(...)) 推入。
            //
            // `isHomeTabActive` 注入：keep-alive 架构下 view 永久持有，view tree 不能用 .task 触发首次拉数据
            // （否则 app 启动即预热）。下游 LiveTabView 据此判断"home 是否真正被用户访问"，做 lazy load。
            NavigationStack(path: $homePath) {
                HomeView()
                    // 详情↔聊天互跳所有 destination(UserProfileRoute + ChatFromProfileRoute) 统一注册
                    .userProfileAndChatDestinations()
                    // 头像 tap 内置分派：非房间态 → push UserProfileRoute 跳详情页（对齐环境自探 .list 分支）
                    .avatarProfilePusher { uid in homePath.append(UserProfileRoute.userId(uid)) }
                    // 客态直播间必须走 homePath，令主 TabBar 与其他首页子页统一隐藏和恢复。
                    .navigationDestination(for: AudienceLiveRoomRoute.self) { route in
                        switch route {
                        case .room(let anchor):
                            AudienceLiveRoomView(anchor: anchor)
                        }
                    }
                    // 首页右上排行榜：Live/List/Match 进全站 Charm/Wealth/CP 榜；Circle 进积分榜。
                    .navigationDestination(for: HomeLeaderboardRoute.self) { route in
                        switch route {
                        case .ranking: HomeRankingView()
                        case .points: PointsRankView()
                        }
                    }
                    .navigationDestination(for: HomeBannerH5Route.self) { route in
                        if let page = route.page {
                            H5WebContainerView(page: page)
                        } else {
                            EmptyView()
                        }
                    }
                    // Home 也持有 WorkRoute destination——QuickGoLive 从 Home 内 push LiveSettings 后,
                    // LiveSettings 内嵌 NavigationLink(WorkRoute.wishSetting/.beautySettings) 也要能
                    // 在同一 stack 内 push。**必须与 Work stack 保持 case 一致**，否则从 Home 入口进入
                    // 开播设置后点 Wishlist / Beauty 会走 EmptyView。
                    // 复用 WorkRoute 类型（不新建 HomeRoute）——LiveSettings 内的链接 value 类型已固定为 WorkRoute，
                    // 换类型需侵入 LiveSettings 源码。
                    .navigationDestination(for: WorkRoute.self) { route in
                        switch route {
                        case .firstLiveRule:  FirstLiveRuleView(path: $homePath)
                        case .liveSettings:   LiveSettingsView()
                        case .wishSetting:    WishSettingView()
                        case .beautySettings: BeautySettingsView()
                        case .giftMessage:    GiftMessageView()
                        case .profileEdit:    EditProfileView(service: EditProfileService.shared)
                        case .liveData:       LiveDataView()
                            .environment(\.moneyBagAction, { homePath.append(WorkRoute.task) })
                        case .task:
                            TaskCenterView()
                                .environment(\.rankProgressAction, { target in
                                    switch target {
                                    case .income: homePath.append(HomeLeaderboardRoute.ranking)
                                    case .integral: homePath.append(WorkRoute.pointsRank)
                                    }
                                })
                        case .wallet:
                            WalletView()
                        case .invite(let source):
                            // 历史 H5 Invite 入口，原生实现上线后不再执行：
                            // H5EmbeddedFeatureContainerView(feature: .invite, title: L10n.toolInvite)
                            InviteView(entrySource: source.rawValue) { audience in
                                let destination: WorkRoute = audience == .user
                                    ? .inviteUserDetails
                                    : .inviteAnchorDashboard
                                AppLogger.net.notice("[Invite] details route append host=home audience=\(audience.rawValue, privacy: .public)")
                                homePath.append(destination)
                            }
                        case .inviteUserDetails:
                            InviteDetailsView()
                        case .inviteAnchorDashboard:
                            InviteAnchorDashboardView()
                        case .pointsRank:     PointsRankView()
                        case .anchorGuide:
                            H5EmbeddedFeatureContainerView(feature: .anchorGuide, title: L10n.toolWorkingGuide)
                        case .partyData:      PartyDataView()
                        case .myGuardian:
                            GuardianListView(anchorId: Int64(SessionStore.shared.user?.userId ?? 0)) { uid in
                                guard (Int64(uid.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 else { return }
                                homePath.append(UserProfileRoute.userId(uid))
                            }
                        case .dataStatistics:  DataStatisticsView()
                        case .newbie:         WorkComingSoonView(title: L10n.toolNewbie)
                        case .bigR:           WorkComingSoonView(title: L10n.toolStarUser)
                        case .props:          PropsMainView()
                        case .propsRules:     PropsRulesView()
                        case .currencyExchange(let tab):
                            PartyCurrencyExchangeView(initialTab: tab)
                        case .liveResult(let begin, let end, let endType):
                            LiveResultView(range: (begin, end), endType: endType, hostPath: $homePath)
                        }
                    }
                    // 结果页 push 私聊页（LiveResultView 从 homePath push String type peerYxAccId）
                    .navigationDestination(for: String.self) { peerYxAccId in
                        let selfYxAccId = SessionStore.shared.user?.yxAccid ?? ""
                        ChatDetailContainer(peerYxAccId: peerYxAccId, selfYxAccId: selfYxAccId)
                    }
            }
            .environment(\.isHomeTabActive, selection == .home)
            .environment(\.openHomeLeaderboard, OpenHomeLeaderboardAction { route in
                homePath.append(route)
            })
            .environment(\.openHomeBanner, OpenHomeBannerAction { route in
                homePath.append(route)
            })
            .environment(\.liveResultTransition, liveResultTransitionAction)
            .environment(\.quickGoLive, QuickGoLiveAction {
                requestLiveEntry(.home)
            })
            .environment(\.audienceGoLive, AudienceGoLiveAction {
                // 客态房间已在调用侧完成 RTC/IM 退出；路径只保留设置页，返回即回首页根页。
                homePath = NavigationPath([WorkRoute.liveSettings])
            })
            .environment(\.liveTermination, liveTerminationAction)
            .environment(\.openChat, openChatAction)
            .environment(\.openUserProfile, openUserProfileAction)
            .opacity(selection == .home ? 1 : 0)
            .allowsHitTesting(selection == .home)
            .accessibilityHidden(selection != .home)

            // —— Messages：永久持有 ——
            // H-1 MVP：P2P 会话列表 shared 单例 + keep-alive；切走再回来保留 selectedCategory /
            // sessions / delegate 订阅。详见 [MessageSessionStoreShared.swift](../Message/MessageSessionStoreShared.swift)
            //
            // H-2：包 NavigationStack path 支持 push 到 ChatDetailContainer（tap row 触发）
            NavigationStack(path: $messagesPath) {
                MessageListView(store: MessageSessionStore.shared, messagesPath: $messagesPath)
                    .navigationDestination(for: String.self) { pathValue in
                        // Batch 3.8：sentinel `__station_list__` → StationListView（独立 HTTP 列表页）
                        if pathValue == MessageListView.stationSentinel {
                            StationListView()
                        } else if pathValue == MessageListView.callRecordsSentinel {
                            // 通话历史记录页（对齐 H5 `/communication?from=news&active=0`）
                            CallRecordListView(path: $messagesPath)
                        } else {
                            let selfYxAccId = SessionStore.shared.user?.yxAccid ?? ""
                            ChatDetailContainer(peerYxAccId: pathValue, selfYxAccId: selfYxAccId)
                        }
                    }
                    // 详情↔聊天互跳所有 destination(UserProfileRoute + ChatFromProfileRoute) 统一注册
                    // —— ChatMessageRow 内 NavigationLink(value: UserProfileRoute) 会走 helper 里的 UserProfileRoute case
                    .userProfileAndChatDestinations()
                    .environment(\.openUserProfile, openUserProfileAction)
                    // 头像 tap 内置分派：非房间态 → push UserProfileRoute 跳详情页
                    .avatarProfilePusher { uid in messagesPath.append(UserProfileRoute.userId(uid)) }
            }
            .opacity(selection == .messages ? 1 : 0)
            .allowsHitTesting(selection == .messages)
            .accessibilityHidden(selection != .messages)

            // —— Party：永久持有（E-spec §6B v4 反悔 2026-07-10 从 if 销毁重建改 keep-alive）——
            // 切走再回 tab 保留 PartyListStore state / rooms / scroll offset，对齐 home/messages 模式。
            // lazy load 由 `isPartyTabActive` env 驱动（对齐 IsHomeTabActiveKey）—— 启动即 mount 但不预热数据，
            // 用户首次点 Party tab 时才 startInitial。
            PartyTabRootView(path: $partyPath)
                .environment(\.isPartyTabActive, selection == .party)
                .opacity(selection == .party ? 1 : 0)
                .allowsHitTesting(selection == .party)
                .accessibilityHidden(selection != .party)

            // —— Work / Profile：if 切换销毁重建 ——
            // 用户接受重新加载；不长持 NavigationStack + WorkView/ProfileView 内的资源。
            if selection == .work {
                NavigationStack(path: $workPath) {
                    WorkView(path: $workPath)
                        .environment(\.quickGoLive, QuickGoLiveAction {
                            requestLiveEntry(.work)
                        })
                        .navigationDestination(for: WorkRoute.self) { route in
                            switch route {
                            case .firstLiveRule:
                                FirstLiveRuleView(path: $workPath)
                            case .liveSettings:
                                LiveSettingsView()
                            case .wishSetting:
                                WishSettingView()
                            case .beautySettings:
                                BeautySettingsView()
                            case .giftMessage:
                                GiftMessageView()
                            case .profileEdit:
                                EditProfileView(service: EditProfileService.shared)
                            case .liveData:
                                LiveDataView()
                                    .environment(\.moneyBagAction, { workPath.append(WorkRoute.task) })
                            case .task:
                                TaskCenterView()
                                    .environment(\.rankProgressAction, { target in
                                        switch target {
                                        case .income: workPath.append(HomeLeaderboardRoute.ranking)
                                        case .integral: workPath.append(WorkRoute.pointsRank)
                                        }
                                    })
                            case .wallet:
                                WalletView()
                            case .invite(let source):
                                // 旧实现：完整复用 H5 Invite。保留注释作为紧急回退参考；
                                // 新实现直接走原生 API，避免把主会话 token 暴露给 WebView。
                                // H5EmbeddedFeatureContainerView(feature: .invite, title: L10n.toolInvite)
                                InviteView(entrySource: source.rawValue) { audience in
                                    let destination: WorkRoute = audience == .user
                                        ? .inviteUserDetails
                                        : .inviteAnchorDashboard
                                    AppLogger.net.notice("[Invite] details route append host=work audience=\(audience.rawValue, privacy: .public)")
                                    workPath.append(destination)
                                }
                            case .inviteUserDetails:
                                InviteDetailsView()
                            case .inviteAnchorDashboard:
                                InviteAnchorDashboardView()
                            case .pointsRank:
                                PointsRankView()
                            case .anchorGuide:
                                H5EmbeddedFeatureContainerView(feature: .anchorGuide, title: L10n.toolWorkingGuide)
                            case .partyData:
                                PartyDataView()
                            case .myGuardian:
                                GuardianListView(anchorId: Int64(SessionStore.shared.user?.userId ?? 0)) { uid in
                                    // H5 `onClickUser` 对 0 不跳转；列表接口的 userId 是数值，iOS 适配为 String 后保留同一约束。
                                    guard (Int64(uid.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 else { return }
                                    workPath.append(UserProfileRoute.userId(uid))
                                }
                            case .dataStatistics:
                                DataStatisticsView()
                            case .newbie:
                                WorkComingSoonView(title: L10n.toolNewbie)
                            case .bigR:
                                WorkComingSoonView(title: L10n.toolStarUser)
                            case .props:
                                PropsMainView()
                            case .propsRules:
                                PropsRulesView()
                            case .currencyExchange(let tab):
                                PartyCurrencyExchangeView(initialTab: tab)
                            case .liveResult(let begin, let end, let endType):
                                LiveResultView(range: (begin, end), endType: endType, hostPath: $workPath)
                            }
                        }
                        .navigationDestination(for: HomeLeaderboardRoute.self) { route in
                            switch route {
                            case .ranking: HomeRankingView()
                            case .points: PointsRankView()
                            }
                        }
                        // 结果页 push 私聊：Work stack String destination（LiveResultView Message 按钮触发）
                        .navigationDestination(for: String.self) { peerYxAccId in
                            let selfYxAccId = SessionStore.shared.user?.yxAccid ?? ""
                            ChatDetailContainer(peerYxAccId: peerYxAccId, selfYxAccId: selfYxAccId)
                        }
                        // 详情↔聊天互跳所有 destination(UserProfileRoute + ChatFromProfileRoute) 统一注册
                        .userProfileAndChatDestinations()
                        // 头像 tap 内置分派：非房间态 → push UserProfileRoute 跳详情页
                        .avatarProfilePusher { uid in workPath.append(UserProfileRoute.userId(uid)) }
                }
                .environment(\.liveResultTransition, liveResultTransitionAction)
                .environment(\.liveTermination, liveTerminationAction)
            .environment(\.openChat, openChatAction)
            .environment(\.openUserProfile, openUserProfileAction)
            .environment(\.openHomeMatch, openHomeMatchAction)
            } else if selection == .profile {
                NavigationStack(path: $profilePath) {
                    ProfileView(path: $profilePath)
                        .navigationDestination(for: FollowSegment.self) { segment in
                            FollowListView(initialSegment: segment)
                        }
                        .navigationDestination(for: ProfileRoute.self) { route in
                            switch route {
                            case .settings:     SettingsView(path: $profilePath)
                            case .levelDetail:  LevelDetailView()
                            case .dataStatistics: DataStatisticsView()
                            case .blocklist:    BlocklistView()
                            case .editProfile:  EditProfileView(service: EditProfileService.shared)
                            case .anchorPolicy: AnchorPolicyView()
                            case .language:     LanguageView()
                            case .feedback:     FeedbackView(path: $profilePath)
                            case .userAgreement:
                                H5WebContainerView(page: H5Page(url: URL(string: AppConfig.termsOfServiceURL)!, title: L10n.settingsTermsOfService))
                            case .privacyPolicy:
                                H5WebContainerView(page: H5Page(url: URL(string: AppConfig.privacyPolicyURL)!, title: L10n.settingsPrivacyPolicy))
                            }
                        }
                        // 详情↔聊天互跳所有 destination + 头像 tap 详情 pusher
                        .userProfileAndChatDestinations()
                        .avatarProfilePusher { uid in profilePath.append(UserProfileRoute.userId(uid)) }
                }
            }
        }
    }

    /// tabbar 永驻容器：用几何坍缩 + 透明度切换隐显，不做 if/EmptyView 增删。
    /// allowsHitTesting / accessibilityHidden 同步切，避免坍缩后误命中或被 VoiceOver 聚焦。
    ///
    /// `liveSettingsLock.isLocked` 拦截触摸（B-spec-开播设置页 §1.4）：
    /// 即使 tabbar 视觉上因子页坍缩为 0 高度，path 非空时它已不响应；`.starting`
    /// 状态下 LiveSettingsView 仍在栈内（path 非空），tabbar 已经拦截，本 lock 兜底
    /// 覆盖"子页突然消失"边界（B 档保守）。
    ///
    /// **背景延伸到 home indicator 安全区**（2026-07-09 修）：
    /// `tabBar` 内部 `.background(screenBackground)` 只覆盖自身 52pt 帧，下方 34pt home indicator
    /// 区裸露；ScrollView 内容（如 Profile 的 Photos 网格）会 rubber-band 进入该区域，视觉上
    /// 表现为"tabbar 和底部安全区没连在一起、内容透出"。故在 clipped 之后再挂一层带
    /// `ignoresSafeArea(.bottom)` 的同色底，随 opacity 一起隐显，不影响子页坍缩动画。
    private var tabBarHostContainer: some View {
        ZStack { tabBar }
            .frame(height: isOnSubpageSignal ? 0 : Theme.Metric.tabBarHeight)
            .clipped()
            .background {
                Theme.Palette.screenBackground
                    .ignoresSafeArea(edges: .bottom)
            }
            .opacity(isOnSubpageSignal ? 0 : 1)
            .allowsHitTesting(!isOnSubpageSignal && !liveSettingsLock.isLocked)
            .accessibilityHidden(isOnSubpageSignal)
            .animation(.easeInOut(duration: 0.25), value: isOnSubpageSignal)
    }

    private var tabBar: some View {
        HStack(alignment: .top, spacing: 0) {
            // P 项目权限管理：userType 命中 .party bit → 过滤掉 party tab（4 icon 变 3 icon）
            ForEach(visibleTabs, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    tabItem(tab, isSelected: selection == tab)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
        .frame(height: Theme.Metric.tabBarHeight)
        .background(Theme.Palette.screenBackground)
    }

    /// P 项目：按权限过滤 tab bar 可见项。userType 命中 .party bit 时 party tab 不渲染。
    /// 若 selection == .party 时 canParty 变 false，通过 `.onChange(of: permission.canParty)` fallback（见 body modifier）。
    private var visibleTabs: [MainTab] {
        MainTab.allCases.filter { tab in
            switch tab {
            case .party: return permission.canParty
            default:     return true
            }
        }
    }

    private func tabItem(_ tab: MainTab, isSelected: Bool) -> some View {
        VStack(spacing: 4) {
            Image(isSelected ? tab.activeIcon : tab.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            Text(tab.label)
                .font(Theme.Typography.tabLabel)
                .foregroundStyle(isSelected ? Theme.Palette.tabActive : Theme.Palette.tabInactiveLabel)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func restoreMinimizedPartyRoom() {
        let partyStore = PartyStore.shared
        guard let roomId = partyStore.roomInfo?.id, !roomId.isEmpty else { return }
        suppressPathClearOnTabChange = true
        partyStore.restoreMinimizedRoom()
        selection = .party
        partyPath = NavigationPath([PartyRoute.room(id: roomId, password: nil)])
        DispatchQueue.main.async { suppressPathClearOnTabChange = false }
    }

    private func leaveMinimizedPartyRoom() {
        let partyStore = PartyStore.shared
        Task { await partyStore.leaveMinimizedRoom() }
    }

    private func requestLiveEntry(_ target: LiveEntryTarget) {
        let partyStore = PartyStore.shared
        guard partyStore.roomState == .joined else {
            openLiveEntry(target)
            return
        }
        guard partyStore.isMinimized else {
            AppToastCenter.shared.show(L10n.Party.mutexBlockedByParty)
            return
        }
        pendingLiveEntryTarget = target
    }

    private func confirmLiveEntryAfterLeavingMinimizedParty() {
        guard let target = pendingLiveEntryTarget else { return }
        pendingLiveEntryTarget = nil
        Task { @MainActor in
            await PartyStore.shared.leaveMinimizedRoom()
            openLiveEntry(target)
        }
    }

    private func openLiveEntry(_ target: LiveEntryTarget) {
        let route: WorkRoute = FirstLiveTracker.isFirstLive ? .firstLiveRule : .liveSettings
        switch target {
        case .home:
            homePath.append(route)
        case .work:
            workPath.append(route)
        }
    }

    private func handleH5NativeDestination(_ destination: H5NativeActionRouter.Destination) {
        switch destination {
        case .wallet:
            selectWorkRoute(.wallet)
        case .ranking(let pageType, let hideMonthTab):
            openActivityRanking(pageType: pageType, hideMonthTab: hideMonthTab)
        case .liveSettings:
            selectWorkForLiveSettings()
        case .partyRoom(let roomId):
            guard permission.canParty else {
                AppToastCenter.shared.show(L10n.commonNoContent)
                return
            }
            suppressPathClearOnTabChange = true
            selection = .party
            partyPath = NavigationPath([PartyRoute.room(id: roomId, password: nil)])
            DispatchQueue.main.async { suppressPathClearOnTabChange = false }
        case .userProfile(let userId):
            openUserProfileAction.perform(userId)
        }
    }

    private func selectWorkRoute(_ route: WorkRoute) {
        suppressPathClearOnTabChange = true
        selection = .work
        workPath = NavigationPath([route])
        DispatchQueue.main.async { suppressPathClearOnTabChange = false }
    }

    private func selectWorkForLiveSettings() {
        suppressPathClearOnTabChange = true
        selection = .work
        workPath = NavigationPath()
        DispatchQueue.main.async {
            suppressPathClearOnTabChange = false
            requestLiveEntry(.work)
        }
    }

    private func openActivityRanking(pageType: String?, hideMonthTab: Bool) {
        switch pageType?.uppercased() {
        case "GAME_TASK":
            guard let page = H5Page.embeddedRanking(pageType: pageType, hideMonthTab: hideMonthTab) else {
                AppLogger.net.error("[H5Bridge] unavailable embedded game-task ranking page")
                return
            }
            activityRankingPage = page
        case "PARTY_ROOM":
            guard permission.canParty else {
                AppToastCenter.shared.show(L10n.commonNoContent)
                return
            }
            suppressPathClearOnTabChange = true
            selection = .party
            partyPath = NavigationPath([PartyRoute.lobbyRanking(.partyRich)])
            DispatchQueue.main.async { suppressPathClearOnTabChange = false }
        default:
            // `NORMAL` 及服务端缺省值均进入现有主播榜；`hideMonthTab` 仅 GAME_TASK 页有业务含义。
            _ = hideMonthTab
            suppressPathClearOnTabChange = true
            selection = .home
            homePath = NavigationPath([HomeLeaderboardRoute.ranking])
            DispatchQueue.main.async { suppressPathClearOnTabChange = false }
        }
    }
}

/// H5 `party-floating.vue` 的应用内小窗。保持在主壳，因而用户切换任意 tab 后仍可恢复 Party 房。
private struct PartyRoomFloatingBubble: View {
    let avatarURL: String?
    let onRestore: () -> Void
    let onLeave: () -> Void

    /// H5 `van-floating-bubble` 的 `gap=12`：拖动中和结束后都不能越过此边距。
    private let edgeGap: CGFloat = 12
    private let containerSize = CGSize(width: 72, height: 64)

    /// H5 的 `offset` 是浮窗左上角坐标；nil 表示使用首次出现的位置。
    @State private var origin: CGPoint?
    @GestureState private var dragTranslation: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let currentOrigin = currentOrigin(in: proxy.size)
            let displayedOrigin = dragTranslation == .zero
                ? currentOrigin
                : clampedOrigin(
                    CGPoint(
                        x: currentOrigin.x + dragTranslation.width,
                        y: currentOrigin.y + dragTranslation.height
                    ),
                    in: proxy.size
                )
            ZStack(alignment: .topLeading) {
                Button(action: onRestore) {
                    bubbleAvatar
                        .frame(width: containerSize.width, height: containerSize.height, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onLeave) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.white)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                // H5 `inset-inline-end:-4 top:-6`。
                .frame(width: containerSize.width, height: containerSize.height, alignment: .topTrailing)
                .offset(x: 4, y: -6)
                .accessibilityLabel(L10n.PartyRoom.moreMenuLeave)
            }
            .frame(width: containerSize.width, height: containerSize.height)
            .position(
                x: displayedOrigin.x + containerSize.width / 2,
                y: displayedOrigin.y + containerSize.height / 2
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .updating($dragTranslation) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        origin = clampedOrigin(
                            CGPoint(
                                x: currentOrigin.x + value.translation.width,
                                y: currentOrigin.y + value.translation.height
                            ),
                            in: proxy.size
                        )
                    }
            )
        }
        .allowsHitTesting(true)
        .accessibilityElement(children: .contain)
    }

    private var bubbleAvatar: some View {
        // H5 三层容器均为 `flex-center`；圆环、渐变底和头像必须共用同一个中心点。
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: 0xFF9438).opacity(0.251),
                            Color(hex: 0xFF0091).opacity(0.5),
                            Color(hex: 0xFE00DE).opacity(0.5)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 64, height: 64)
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: 0xFF9438).opacity(0.251),
                            Color(hex: 0xFF0091).opacity(0.5),
                            Color(hex: 0xFE00DE).opacity(0.5)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 58, height: 58)
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0xFF9438), Color(hex: 0xFF0091), Color(hex: 0xFE00DE)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                AvatarView(urlString: avatarURL, size: 50, kind: .user, disablesTap: true)
                    .clipShape(Circle())
            }
            .frame(width: 52, height: 52)
            .overlay(alignment: .bottom) {
                // 动图保持在头像框内底部，避免参与 ZStack 布局把头像和背景顶偏。
                PartyFloatingGIFView()
                    .frame(width: 34, height: 15.57)
                    .padding(.bottom, 6)
            }
        }
        .frame(width: 64, height: 64)
        .accessibilityLabel(L10n.tabParty)
    }

    private func currentOrigin(in container: CGSize) -> CGPoint {
        origin ?? initialOrigin(in: container)
    }

    /// 对齐 H5 `offset = { x: viewWidth - (78 * (viewWidth / 375)), y: 100 }`。
    private func initialOrigin(in container: CGSize) -> CGPoint {
        CGPoint(
            x: container.width - 78 * (container.width / 375),
            y: 100
        )
    }

    private func clampedOrigin(_ origin: CGPoint, in container: CGSize) -> CGPoint {
        let minX = edgeGap
        let maxX = max(minX, container.width - containerSize.width - edgeGap)
        let minY = edgeGap
        let maxY = max(minY, container.height - containerSize.height - edgeGap)
        return CGPoint(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY)
        )
    }
}

/// Party 最小化球底部的循环 GIF。资源随 App 打包，避免每次展示请求 CDN。
private struct PartyFloatingGIFView: View {
    var body: some View {
        AnimatedGIFView(name: "party-list-animation")
            .scaledToFill()
            .clipped()
    }
}

/// 5 个 tab 定义（图标取切图，标签走 i18n）。
///
/// 声明顺序 = allCases = tabbar 渲染顺序：home / messages / **party** / work / profile
/// （E-spec §6B v3：party 插第 3 位，居中焦点 tab，对齐主流直播 App"发现/派对"tab 中心突出模式）
enum MainTab: CaseIterable {
    case home, messages, party, work, profile

    /// 未选中态切图（浅紫静态色调）
    var icon: String {
        switch self {
        case .home:     return "tabHome"
        case .messages: return "tabMessages"
        case .party:    return "tabParty"
        case .work:     return "tabWork"
        case .profile:  return "tabProfile"
        }
    }

    /// 选中态切图（橙红渐变彩色）
    var activeIcon: String {
        switch self {
        case .home:     return "tabHomeActive"
        case .messages: return "tabMessagesActive"
        case .party:    return "tabPartyActive"
        case .work:     return "tabWorkActive"
        case .profile:  return "tabProfileActive"
        }
    }

    var label: String {
        switch self {
        case .home:     return L10n.tabHome
        case .messages: return L10n.tabMessages
        case .party:    return L10n.tabParty
        case .work:     return L10n.tabWork
        case .profile:  return L10n.tabProfile
        }
    }
}

// MARK: - EnvironmentKey

/// 标记 home tab 是否被用户选中。MainTabView 注入，LiveTabView/CircleView 等下游消费。
///
/// **设计动机**：home tab 采用 ZStack opacity 的 keep-alive 架构，view tree 永久持有 →
/// `.task` / `.onAppear` 不在用户切到 home 时触发（启动时即触发）。
/// 下游需要"home 是否真正访问"信号来做 lazy load —— 避免启动即预热朋友圈 / List 数据。
private struct IsHomeTabActiveKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var isHomeTabActive: Bool {
        get { self[IsHomeTabActiveKey.self] }
        set { self[IsHomeTabActiveKey.self] = newValue }
    }
}

/// 标记 party tab 是否被用户选中（E-spec §6B v4）。
///
/// **设计动机**：party tab 采 ZStack opacity keep-alive → PartyTabRootView 永久 mount，
/// `.task` / `.onAppear` 不在用户切到 party 时触发（启动即触发）。
/// 下游 PartyRoomListView 据此判断"party 是否真正被用户访问"做 lazy load —— 避免启动即预热房间列表。
private struct IsPartyTabActiveKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var isPartyTabActive: Bool {
        get { self[IsPartyTabActiveKey.self] }
        set { self[IsPartyTabActiveKey.self] = newValue }
    }
}

/// 首页右上榜单跨层导航。LiveTabView 不持有 NavigationPath，按现有 QuickGoLive 模式由根壳注入。
struct OpenHomeLeaderboardAction {
    let perform: (_ route: HomeLeaderboardRoute) -> Void
    static let noop = OpenHomeLeaderboardAction(perform: { _ in })
}

private struct OpenHomeLeaderboardKey: EnvironmentKey {
    static let defaultValue: OpenHomeLeaderboardAction = .noop
}

extension EnvironmentValues {
    var openHomeLeaderboard: OpenHomeLeaderboardAction {
        get { self[OpenHomeLeaderboardKey.self] }
        set { self[OpenHomeLeaderboardKey.self] = newValue }
    }
}

/// 首页 banner WebView route。对齐 H5 `banner.vue` + `CGoToIframe`：
/// - 空 URL 不跳转
/// - `lottery` URL 的 `reportParams={path:banner}` 进入 Bridge runtime，而不留在 URL
/// - `isHuanNiuOwnH5` 折成当前 iOS H5 站点内部页面
struct HomeBannerH5Route: Hashable {
    let originalURLString: String
    let resolvedURLString: String
    let reportPath: String?
    let isInternalH5Route: Bool

    init?(item: AppPictureItem) {
        guard let raw = item.directUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let resolved = Self.resolve(raw) else {
            return nil
        }
        self.originalURLString = raw
        self.resolvedURLString = resolved.url.absoluteString
        self.reportPath = resolved.reportPath
        self.isInternalH5Route = resolved.isInternalH5Route
    }

    @MainActor
    var page: H5Page? {
        guard let url = URL(string: resolvedURLString) else { return nil }
        return H5Page.banner(url: url, reportPath: reportPath ?? "banner")
    }

    private static func resolve(_ raw: String) -> (url: URL, reportPath: String?, isInternalH5Route: Bool)? {
        if raw.contains("isHuanNiuOwnH5") {
            guard let url = internalURL(from: raw) else { return nil }
            return (url, nil, true)
        }

        guard let url = URL(string: raw) else { return nil }
        if raw.contains("lottery"), let strippedURL = strippedLotteryRuntimeURL(url) {
            return (strippedURL, "banner", false)
        }
        return (url, nil, false)
    }

    private static func internalURL(from raw: String) -> URL? {
        let base = "https://ios-web.netlify.app"
        if let externalURL = URL(string: raw), externalURL.host != nil {
            // 老链接可能使用 hash 路由，fragment 本身就是当前 H5 的 history path。
            if let fragment = externalURL.fragment, fragment.hasPrefix("/") {
                return URL(string: base + fragment)
            }
            guard var components = URLComponents(string: base) else { return nil }
            components.path = externalURL.path.isEmpty ? "/" : externalURL.path
            components.query = externalURL.query
            return components.url
        }

        let path = raw.hasPrefix("/") ? raw : "/\(raw)"
        return URL(string: base + path)
    }

    private static func strippedLotteryRuntimeURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { ["roomId", "roomType", "reportParams"].contains($0.name) }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }
}

struct OpenHomeBannerAction {
    let perform: (_ route: HomeBannerH5Route) -> Void
    static let noop = OpenHomeBannerAction(perform: { _ in })
}

private struct OpenHomeBannerKey: EnvironmentKey {
    static let defaultValue: OpenHomeBannerAction = .noop
}

extension EnvironmentValues {
    var openHomeBanner: OpenHomeBannerAction {
        get { self[OpenHomeBannerKey.self] }
        set { self[OpenHomeBannerKey.self] = newValue }
    }
}

/// 跨 tab 导航 action：Home Live tab 的 QuickGoLiveButton 触发时切到 Work tab + push LiveSettings。
///
/// **设计动机**：`LiveSettingsView` 挂在 Work NavigationStack 的 `WorkRoute.liveSettings`，
/// 单一入口避免多 tab 持有同一 view 导致 state 冲突。CGoLive 对齐 H5：进入开播设置流程。
struct QuickGoLiveAction {
    let perform: () -> Void
    static let noop = QuickGoLiveAction(perform: {})
}

/// 客态房间的开播动作。与首页浮动开播不同，它替换当前 home path，不能把已退出的客态房间留在返回栈中。
struct AudienceGoLiveAction {
    let perform: () -> Void
    static let noop = AudienceGoLiveAction(perform: {})
}

private struct AudienceGoLiveKey: EnvironmentKey {
    static let defaultValue: AudienceGoLiveAction = .noop
}

extension EnvironmentValues {
    var audienceGoLive: AudienceGoLiveAction {
        get { self[AudienceGoLiveKey.self] }
        set { self[AudienceGoLiveKey.self] = newValue }
    }
}

private struct QuickGoLiveKey: EnvironmentKey {
    static let defaultValue: QuickGoLiveAction = .noop
}

extension EnvironmentValues {
    var quickGoLive: QuickGoLiveAction {
        get { self[QuickGoLiveKey.self] }
        set { self[QuickGoLiveKey.self] = newValue }
    }
}

/// 跨 tab 打开 P2P 私聊页（对齐 H5 CGoToChat 全局跳转）。
///
/// **使用场景**：直播结果页（TopGifter / PrivateCall / GifterFull）点 Message 按钮 → 跳私聊。
/// 未来 LiveList / Profile 侧栏等入口按同 pattern 接入。
///
/// **实现动作**（同 LiveTerminationAction 精神）：切 tab 到 .messages + 清 homePath/workPath +
/// 用 `[peerYxAccId]` 重建 messagesPath 让 NavigationStack 直达 ChatDetailContainer。
struct OpenChatAction {
    let perform: (_ peerYxAccId: String) -> Void
    static let noop = OpenChatAction(perform: { _ in })
}

private struct OpenChatKey: EnvironmentKey {
    static let defaultValue: OpenChatAction = .noop
}

extension EnvironmentValues {
    var openChat: OpenChatAction {
        get { self[OpenChatKey.self] }
        set { self[OpenChatKey.self] = newValue }
    }
}

/// 跨 view 打开用户详情页 action(对齐 openChatAction 模式)。
/// 用于 ChatDetailView 内系统消息 tap "ID 12345" 跳详情等无法用 NavigationLink 声明式承载的场景。
/// 实现:append UserProfileRoute 到当前 tab path,让已注册的 navigationDestination 承接。
struct OpenUserProfileAction {
    private let handler: (_ userId: String) -> Void

    init(_ handler: @escaping (_ userId: String) -> Void) {
        self.handler = handler
    }

    func perform(_ rawUserId: String) {
        let userId = rawUserId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userId.isEmpty else { return }
        handler(userId)
    }

    static let noop = OpenUserProfileAction { _ in }
}

private struct OpenUserProfileKey: EnvironmentKey {
    static let defaultValue: OpenUserProfileAction = .noop
}

extension EnvironmentValues {
    var openUserProfile: OpenUserProfileAction {
        get { self[OpenUserProfileKey.self] }
        set { self[OpenUserProfileKey.self] = newValue }
    }
}

/// 直播结束 → 结果页显示 action（**B spec v7 push 架构**：从 fullScreenCover 改为 push 页面）。
///
/// LiveRoomView state=.ended 时触发；MainTabView 内闭包切 Work tab + 把当前活跃 path 重建为
/// `[WorkRoute.liveResult(...)]` 单层 —— LiveRoomView + LiveSettings 全 dismount，结果页作为新根出现。
/// 用户从结果页 back → pop 到 Work 根；swipe-back 原生支持；无 modal 覆盖语义。
struct LiveResultTransitionAction {
    let perform: (_ begin: Int64?, _ end: Int64?, _ endType: Int?) -> Void
    static let noop = LiveResultTransitionAction(perform: { _, _, _ in })
}

private struct LiveResultTransitionKey: EnvironmentKey {
    static let defaultValue: LiveResultTransitionAction = .noop
}

extension EnvironmentValues {
    var liveResultTransition: LiveResultTransitionAction {
        get { self[LiveResultTransitionKey.self] }
        set { self[LiveResultTransitionKey.self] = newValue }
    }
}

/// 直播结束页 back 语义（对齐 H5 liveEnds/index.vue `leavePage` → `initLiveData + router.push('/')`）。
///
/// 结果页 back 时通过本 env 通知外壳：切 MainTab 到 home + 清 workPath/homePath；结果页作为
/// LiveRoomView `.fullScreenCover` 挂载，随 nav 栈自然 dismantle 时 LiveRoomView.onDisappear
/// 负责摄像头/RTC/NIM 清理。LiveStore.reset() 也在此 action 内调，把状态机拨回 .idle。
struct LiveTerminationAction {
    let perform: () -> Void
    static let noop = LiveTerminationAction(perform: {})
}

private struct LiveTerminationKey: EnvironmentKey {
    static let defaultValue: LiveTerminationAction = .noop
}

extension EnvironmentValues {
    var liveTermination: LiveTerminationAction {
        get { self[LiveTerminationKey.self] }
        set { self[LiveTerminationKey.self] = newValue }
    }
}

/// Work `ToolsSection` Match 图标点击 → 切 Home tab + 请求 LiveTabView 切 Match top tab。
///
/// **动机**：Work Match 图标之前只是装饰（无 tap action）。业务上应对齐首页 Match 入口。
/// 用 env action + `HomeNavigationBus` 消息总线避免 hoisting `HomeTopTabStore`。
struct OpenHomeMatchAction {
    let perform: () -> Void
    static let noop = OpenHomeMatchAction(perform: {})
}

private struct OpenHomeMatchKey: EnvironmentKey {
    static let defaultValue: OpenHomeMatchAction = .noop
}

extension EnvironmentValues {
    var openHomeMatch: OpenHomeMatchAction {
        get { self[OpenHomeMatchKey.self] }
        set { self[OpenHomeMatchKey.self] = newValue }
    }
}

/// 未实现 tab 的占位页。
struct PlaceholderTab: View {
    let title: String

    var body: some View {
        ZStack {
            Theme.Palette.screenBackground.ignoresSafeArea()
            Text(title)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}
