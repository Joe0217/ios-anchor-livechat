import SwiftUI

/// 底部 4 tab 主壳。设计稿无原生 tab 栏样式（深色、无分隔线、激活态仅靠颜色区分），
/// 故用自定义 tab 栏 + safeAreaInset，使内容自动避让，不被遮挡。
///
/// 通用规则：tabbar 仅在 4 个 tab 根页显示；任何 push 入栈的子页（含未来新增）一律隐藏 tabbar。
/// 实现：Work / Profile 的 NavigationStack path 均上抬到本视图持有，由派生 Equatable
/// `SubpageSignal` 统一驱动 `isOnSubpage`，单 `onChange` 触发 250ms easeInOut 几何坍缩 + 淡出。
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
    @State private var selection: MainTab = .home
    @State private var homePath: NavigationPath = NavigationPath()
    @State private var workPath: NavigationPath = NavigationPath()
    /// H-2 spec §4.1：Messages tab 加 NavigationStack path 支持 push ChatDetailView（对齐 homePath 模式）
    @State private var messagesPath: NavigationPath = NavigationPath()
    @State private var profilePath: NavigationPath = NavigationPath()
    @State private var isOnSubpage: Bool = false
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
    private var openChatAction: OpenChatAction {
        OpenChatAction { peerYxAccId in
            guard !peerYxAccId.isEmpty else { return }
            selection = .messages
            homePath = NavigationPath()
            workPath = NavigationPath()
            messagesPath = NavigationPath([peerYxAccId])
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
        case .profile:  return !profilePath.isEmpty
        default:        return false
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
        .onChange(of: isOnSubpageSignal) { newValue in
            // 后台时 SwiftUI 仍可能调度 onChange（v5.3.3 已知坑），避免动画 backlog
            guard scenePhase != .background else {
                isOnSubpage = newValue
                return
            }
            withAnimation(.easeInOut(duration: 0.25)) {
                isOnSubpage = newValue
            }
            // L 里程碑：子页拦截 tip 弹窗（对齐 H5 c-goMatch 仅挂 home 页面语义 —— 直播间/详情页/开播设置等均不弹）
            // 通话态由 RootView.CallView zIndex 100 全屏覆盖，tip zIndex 50 视觉上已被盖，无需额外 gate
            matchPopupCoordinator.updateBlockedByOtherPage(newValue)
        }
        .onChange(of: selection) { _ in
            // 程序驱动切换（如 liveResultTransition 结束直播切 Work + 重建 workPath 为 [.liveResult]）
            // 必须跳过清 path，避免覆盖 action 内同帧刚设置的路径（review 202607091438 P1）
            guard !suppressPathClearOnTabChange else { return }
            // 切走 tab 立即清空各 tab 的 path，切回时回到根页
            homePath = NavigationPath()
            workPath = NavigationPath()
            messagesPath = NavigationPath()   // H-2：Messages tab 切走时也回根页
            profilePath = NavigationPath()
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
            // L 里程碑：一次性 attach 全局匹配摄像头会话到 MatchStore.shared
            MatchStore.shared.attachCameraSession(matchCameraSession)
            // L 里程碑 #3c：启动 10 分钟提示弹窗调度
            matchPopupCoordinator.start()
        }
        // 观察 scenePhase 更新 popupCoordinator.appHidden 用于组合态 gate
        .onChange(of: scenePhase) { newPhase in
            matchPopupCoordinator.updateAppHidden(newPhase != .active)
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
        // L 里程碑 #3c：10 分钟提示弹窗（全局跨 tab）
        .overlay {
            if matchPopupCoordinator.isShowing {
                MatchTipPopup(
                    onGoMatch: {
                        matchPopupCoordinator.dismiss()
                        Task { @MainActor in
                            if MatchStore.shared.isFirstMatchToday {
                                // 首日走规则弹窗（CGoMatchButton 内挂载；这里不重复启动）
                                // 直接切到 Match tab + tip dismiss，等用户主动点开关
                            } else {
                                await MatchStore.shared.openMatch()
                            }
                        }
                    },
                    onNoReminder: {
                        matchPopupCoordinator.markTodayNoReminder()
                    },
                    onClose: {
                        matchPopupCoordinator.dismiss()
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
        // Match toast 全局展示（用户 tap 匹配 → openMatch 各失败/成功分支的 UI 反馈）
        // 之前 lastToast 有 11 处写入但 0 UI 消费 → 用户看不到"为什么没开启" —— 现补 overlay
        .overlay(alignment: .top) {
            if let toast = matchStore.lastToast {
                Text(toast.localized)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.black.opacity(0.8), in: Capsule())
                    .padding(.top, 12)
                    .transition(.opacity)
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
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
                    .navigationDestination(for: UserProfileRoute.self) { route in
                        if case let .userId(uid) = route {
                            UserProfileView(userId: uid)
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
                        case .pocDebug:       POCDebugView()
                        case .newbie:         WorkComingSoonView(title: L10n.toolNewbie)
                        case .bigR:           WorkComingSoonView(title: L10n.toolBigR)
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
            .environment(\.liveResultTransition, liveResultTransitionAction)
            .environment(\.quickGoLive, QuickGoLiveAction {
                // 在当前 Home NavigationStack 内 push LiveSettings（对齐用户偏好：
                // 不切 tab、保持上下文;比 H5 CGoLive 切 tab 更内聚）。
                // 首次开播 → 先 push firstLiveRule 10s 规则页（对齐 H5 c-goLive.vue:64 isFirstLive 判断）
                homePath.append(FirstLiveTracker.isFirstLive
                                ? WorkRoute.firstLiveRule
                                : WorkRoute.liveSettings)
            })
            .environment(\.liveTermination, liveTerminationAction)
            .environment(\.openChat, openChatAction)
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
                        } else {
                            let selfYxAccId = SessionStore.shared.user?.yxAccid ?? ""
                            ChatDetailContainer(peerYxAccId: pathValue, selfYxAccId: selfYxAccId)
                        }
                    }
            }
            .opacity(selection == .messages ? 1 : 0)
            .allowsHitTesting(selection == .messages)
            .accessibilityHidden(selection != .messages)

            // —— Work / Profile：if 切换销毁重建 ——
            // 用户接受重新加载；不长持 NavigationStack + WorkView/ProfileView 内的资源。
            if selection == .work {
                NavigationStack(path: $workPath) {
                    WorkView(path: $workPath)
                        .navigationDestination(for: WorkRoute.self) { route in
                            switch route {
                            case .pocDebug:
                                POCDebugView()
                            case .firstLiveRule:
                                FirstLiveRuleView(path: $workPath)
                            case .liveSettings:
                                LiveSettingsView()
                            case .wishSetting:
                                WishSettingView()
                            case .beautySettings:
                                BeautySettingsView()
                            case .newbie:
                                WorkComingSoonView(title: L10n.toolNewbie)
                            case .bigR:
                                WorkComingSoonView(title: L10n.toolBigR)
                            case .giftMessage:
                                GiftMessageView()
                            case .liveResult(let begin, let end, let endType):
                                LiveResultView(range: (begin, end), endType: endType, hostPath: $workPath)
                            }
                        }
                        // 结果页 push 私聊/详情：Work stack 需要 String + UserProfileRoute destination
                        .navigationDestination(for: String.self) { peerYxAccId in
                            let selfYxAccId = SessionStore.shared.user?.yxAccid ?? ""
                            ChatDetailContainer(peerYxAccId: peerYxAccId, selfYxAccId: selfYxAccId)
                        }
                        .navigationDestination(for: UserProfileRoute.self) { route in
                            if case let .userId(uid) = route {
                                UserProfileView(userId: uid)
                            }
                        }
                }
                .environment(\.liveResultTransition, liveResultTransitionAction)
                .environment(\.liveTermination, liveTerminationAction)
            .environment(\.openChat, openChatAction)
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
                            case .blocklist:    BlocklistView()
                            case .editProfile:  EditProfileView(service: EditProfileService.shared)
                            case .anchorPolicy: AnchorPolicyView()
                            case .language:     LanguageView()
                            case .feedback:     FeedbackView(path: $profilePath)
                            }
                        }
                }
            }
        }
    }

    /// tabbar 永驻容器：用几何坍缩 + 透明度切换隐显，不做 if/EmptyView 增删。
    /// allowsHitTesting / accessibilityHidden 同步切，避免坍缩后误命中或被 VoiceOver 聚焦。
    ///
    /// `liveSettingsLock.isLocked` 拦截触摸（B-spec-开播设置页 §1.4）：
    /// 即使 tabbar 视觉上因子页坍缩为 0 高度，isOnSubpage=true 时它已不响应；`.starting`
    /// 状态下 LiveSettingsView 仍在栈内（isOnSubpage=true），tabbar 已经拦截，本 lock 兜底
    /// 覆盖"子页突然消失"边界（B 档保守）。
    private var tabBarHostContainer: some View {
        ZStack { tabBar }
            .frame(height: isOnSubpage ? 0 : Theme.Metric.tabBarHeight)
            .clipped()
            .opacity(isOnSubpage ? 0 : 1)
            .allowsHitTesting(!isOnSubpage && !liveSettingsLock.isLocked)
            .accessibilityHidden(isOnSubpage)
    }

    private var tabBar: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(MainTab.allCases, id: \.self) { tab in
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
}

/// 4 个 tab 定义（图标取切图，标签走 i18n）。
enum MainTab: CaseIterable {
    case home, messages, work, profile

    /// 未选中态切图（浅紫静态色调）
    var icon: String {
        switch self {
        case .home:     return "tabHome"
        case .messages: return "tabMessages"
        case .work:     return "tabWork"
        case .profile:  return "tabProfile"
        }
    }

    /// 选中态切图（橙红渐变彩色）
    var activeIcon: String {
        switch self {
        case .home:     return "tabHomeActive"
        case .messages: return "tabMessagesActive"
        case .work:     return "tabWorkActive"
        case .profile:  return "tabProfileActive"
        }
    }

    var label: String {
        switch self {
        case .home:     return L10n.tabHome
        case .messages: return L10n.tabMessages
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

/// 跨 tab 导航 action：Home Live tab 的 QuickGoLiveButton 触发时切到 Work tab + push LiveSettings。
///
/// **设计动机**：`LiveSettingsView` 挂在 Work NavigationStack 的 `WorkRoute.liveSettings`，
/// 单一入口避免多 tab 持有同一 view 导致 state 冲突。CGoLive 对齐 H5：进入开播设置流程。
struct QuickGoLiveAction {
    let perform: () -> Void
    static let noop = QuickGoLiveAction(perform: {})
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
