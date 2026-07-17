import SwiftUI

/// 派对房主舞台（设计稿视觉重排 2026-07-11）。
///
/// **本次重写只重排视觉**，所有状态机 / RTC / IM / 礼物 / 邀请 / 自动离线 wiring 与旧版一致：
/// - `handleAppear` / `handleDisappear`：进退房 + 自动离线 suspend/resume
/// - `handleSeatListChange`：seatList 变化时更新 sortedSeatsCache
/// - `inviteAlertButtons` / `inviteAlertMessage`：视频位邀请
/// - `selfActionsButtons`：自己麦位操作 sheet
/// - `handleSeatTap`：麦位点击分流
/// - `sendText` / `sendDemoGift`：公屏 / 送礼
/// - `.giftEffectScene`：礼物特效场景绑定
///
/// **视觉层新增**：
/// - 全屏 partyRoomBg 背景图 + 深色遮罩
/// - 顶部主播条（PartyRoomAnchorBar）
/// - 3 大位（前 3 个 seatIndex）+ 10 小位（后续）
/// - 聊天区（tab strip + welcome + PartyMessageListView）
/// - 底部输入 + 5 工具按钮（PartyRoomInputBar）
struct PartyRoomView: View {
    let roomId: String
    /// v8：密码房进房时传入（对齐 H5 clickRoomItem 密码框语义）；普通房传 nil
    var password: String? = nil

    @ObservedObject private var store = PartyStore.shared
    @Environment(\.dismiss) private var dismiss
    /// v5.3.3 真根因坑：SwiftUI 在 ScenePhase=.background 时也会调度 onDisappear，
    /// 必须双守卫防误退房。
    @Environment(\.scenePhase) private var scenePhase

    /// v16.10：内嵌 TextField 文本 state（对齐 LiveRoomView `inputText`）
    @State private var inputText: String = ""
    /// v16.10：输入框 focus state 桥（focused 时 PartyRoomInputBar 收起右侧按钮，TextField 占满宽度）
    @FocusState private var isInputFocused: Bool
    /// v16.11：键盘高度（`UIResponder.keyboardWillShow/Hide` 订阅）—— inputBar 手动 padding 上移
    @State private var keyboardHeight: CGFloat = 0
    @State private var showSelfActions: Bool = false
    @State private var showError: Bool = false
    @State private var didStartEnter: Bool = false
    /// v8 房主设置页 sheet（保留供其他路径直接触发；v8.1 主入口改走 activeRoomTool = .settings）
    @State private var showSettings: Bool = false
    /// v8.1 房间工具 sheet（enum-driven 单 sheet 切换，规避 iOS 16 双 sheet race）
    @State private var activeRoomTool: PartyRoomToolSheetKind? = nil
    /// tools sheet 内 stub 项 tap 时 toast
    @State private var stubToolToast: String? = nil
    /// E v2 §1：Room Mode 二次确认 sheet 之间共享的 pending tempId（模板 grid 选中 → 弹确认 sheet）
    @State private var pendingRoomModeTempId: Int? = nil
    /// v9：公告只读 sheet 显隐（对齐 H5 announcement-popup.vue，MVP 只读；房主/房管编辑权限 F 期补）
    @State private var showAnnouncement: Bool = false
    // F 期房主管理批（2026-07-17）房主编辑通告态
    @State private var isEditingAnnouncement: Bool = false
    @State private var announcementDraft: String = ""
    @State private var isSavingAnnouncement: Bool = false
    // F 期便利功能（2026-07-17）ShareLink 深链分享态；非 nil 触发 UIActivityViewController
    @State private var shareItems: [Any]?
    /// v9：更多菜单 action sheet 显隐（对齐 H5 more-tool-popup.vue Minimize/Exit）
    @State private var showMoreActions: Bool = false
    // v16（2026-07-14）：关注态改从 `store.isFollowingAnchor` 读，进房时 room/enter 接口的
    // `isFollowOwner` 字段初始化；本地 @State 已删除以避免"退出重进显示未关注"的状态漂移。
    /// v12：底部工具栏 message 按钮 → 复用 Live 侧 ConversationSheetContent 半屏消息列表
    @State private var showMessageSheet: Bool = false
    /// v12：底部工具栏 toolMenu 按钮 confirmationDialog（对齐 H5 party-tool-menu.vue PK/Lucky Number/Room Mute）
    @State private var showToolMenu: Bool = false
    /// v12：消息未读徽章（对齐 [swiftui-keepalive-publisher-isolation] 复用 Live 侧 bridge pattern）
    @StateObject private var unreadBridge = MessageEntryUnreadBridge()
    /// P2-10：sortedSeats 缓存
    @State private var sortedSeatsCache: [PartyRoomSeat] = []
    /// 聊天区 tab（视觉状态本地维护；MVP 阶段 All/Chat/Gift 共用同一消息列表，
    /// 实际按 kind 过滤留待 F 期在 PartyMessageListView 内实现）
    @State private var chatFilter: PartyRoomChatFilter = .all
    /// v15：他人麦位 tap → UserCardPopup 显示（对齐 H5 openUserCard；nil = 不显示）
    @State private var userCardForUserId: String? = nil
    /// v15：已在 A 麦位点 B 空位 → 切麦确认（对齐 H5 EnterSwitchPopup；nil = 不显示）
    @State private var switchSeatPendingTarget: PartyRoomSeat? = nil
    /// v15：房主/房管点空位 → 弹管理动作 dialog（Take/Lock/Unlock；对齐 H5 my-mic-tool.vue 简化版）
    @State private var adminSeatActionsTarget: PartyRoomSeat? = nil
    /// v15：房主/房管点他人占用位 → 弹管理动作 dialog（Mute/Unmute + View Profile；对齐 H5 feachProhibitSeat 语义）
    @State private var otherSeatAdminActionsTarget: PartyRoomSeat? = nil
    /// H-5：礼物面板 sheet 显隐（点底部礼物 icon 触发；对齐 H5 party-gift-popup.vue showPartyGiftPopup）
    @State private var showGiftPanel: Bool = false
    /// H-5：送礼成功 toast（sheet 内触发；主 body overlay 显示避免被 sheet 遮挡）
    @State private var giftSentToast: String? = nil
    /// F 里程碑（2026-07-17）：表情面板 sheet 显隐（对齐 H5 party-expression-popup.vue showEmojiPopup）
    @State private var showExpressionPanel: Bool = false

    // MARK: - F-1a PartyBattle 状态（Task 21-22, 2026-07-17）

    /// PartyBattle 状态机（对齐 spec §6.2 布局叠加；sheet 触发由 handlePkTap 分流）
    @ObservedObject private var battleStore = PartyBattleStore.shared
    /// 房主 PK 发起弹窗 sheet 显隐
    @State private var showBattleInitiate: Bool = false
    /// 房主 PK 强制结束确认 sheet 显隐
    @State private var showBattleForceEnd: Bool = false
    /// 冷却期点 PK 提示 toast 显隐（自清 2s）
    @State private var showBattleCooldownToast: Bool = false
    /// PK 规则弹窗 sheet 显隐
    @State private var showBattleRules: Bool = false
    // MARK: - 顶层 body

    var body: some View {
        sceneBody
            .giftEffectScene(.party, scopeId: store.roomInfo?.id ?? roomId)
            // v23（2026-07-13）派对房进场特效：与 giftEffectScene 并列驱动 EnterEffectCenter
            // scopeId 同源用 roomInfo?.id（与 PartyStore.didReceiveEnterAnimation 内 EnterEffectCenter.enqueue 的 scopeId 强对齐）
            .enterEffectScene(.party, scopeId: store.roomInfo?.id ?? roomId)
            // v16.14：不再挂 .ignoresSafeArea(.keyboard) —— 换新架构：
            // inputBar 从 contentColumn VStack 拆出到 stageContent ZStack 作独立 sibling（alignment: .bottom），
            // contentColumn 挂 .ignoresSafeArea(.keyboard) 阻止避让。SwiftUI 默认避让只作用于 inputBar 层，
            // 自动上移到键盘顶部 0 空隙（Workflow 3 agent 一致诊断结论）。
    }

    /// 拆两层规避 SwiftUI type-check timeout（[swiftui-body-type-check-timeout] rule）：
    /// body 已含 modifier + 嵌套 ZStack，直接挂 alert/toolbar/onAppear 编译器负载过高。
    private var sceneBody: some View {
        stageContentWithFooterOverlays
            // 隐藏 nav bar：Party 房是全屏视觉铺满自定义顶栏，无系统 nav bar。
            // 保留 navigationBarBackButtonHidden 副作用禁 interactive pop（对齐 [default-swipe-back-on-push-pages] 业务态防误退例外）。
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { settingsSheet.giftPanelSheetBackground() }
            .sheet(isPresented: $showAnnouncement) { announcementSheet.giftPanelSheetBackground() }
            // F 期便利功能（2026-07-17）ShareLink 深链分享：@State 触发 UIActivityViewController
            .sheet(
                isPresented: Binding(
                    get: { shareItems != nil },
                    set: { if !$0 { shareItems = nil } }
                )
            ) {
                if let items = shareItems {
                    PartyShareSheet(items: items)
                }
            }
            // v8.1 房间工具 sheet（单一挂点，enum 切换 tools / settings 内嵌 push）
            .sheet(item: $activeRoomTool) { kind in
                roomToolContent(kind: kind).giftPanelSheetBackground()
            }
            // H-5：底部礼物 icon → CommonGiftPanel sheet（对齐 H5 party-gift-popup.vue）
            .sheet(isPresented: $showGiftPanel) { giftPanelSheet }
            // F 里程碑（2026-07-17）表情面板 sheet 挂载（对齐 H5 party-expression-popup.vue · 半屏 fraction 0.5）
            .sheet(isPresented: $showExpressionPanel) {
                PartyExpressionPanel()
                    .giftPanelSheetBackground()
                    .presentationDetents([.fraction(0.5)])
            }
            // H-5：送礼成功 toast（sheet 内触发，主 body overlay 避免被 sheet 遮挡）
            .overlay(alignment: .top) {
                if let t = giftSentToast {
                    Text(t)
                        .toastStyle()
                        .transition(Toast.transition)
                        .task(id: t) {
                            try? await Task.sleep(nanoseconds: Toast.dismissDurationNanos)
                            giftSentToast = nil
                        }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: giftSentToast == nil)
            .overlay(alignment: .top) {
                if let t = stubToolToast {
                    Text(t)
                        .toastStyle()
                        .transition(Toast.transition)
                        .task(id: t) {
                            try? await Task.sleep(nanoseconds: Toast.dismissDurationNanos)
                            stubToolToast = nil
                        }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: stubToolToast == nil)
            .confirmationDialog(L10n.PartyRoom.moreMenuTitle, isPresented: $showMoreActions, titleVisibility: .visible) {
                moreActionsButtons
            }
            .onAppear(perform: handleAppear)
            .onChange(of: store.seatList, perform: handleSeatListChange)
            .onDisappear(perform: handleDisappear)
            .alert(L10n.Party.inviteTitle, isPresented: invitePresented) {
                inviteAlertButtons
            } message: {
                inviteAlertMessage
            }
            .alert(L10n.Party.alertTitle, isPresented: $showError) {
                Button(L10n.Party.ok) { store.clearLastError() }
            } message: {
                Text(store.lastError?.errorDescription ?? "")
            }
            .onChange(of: store.lastError?.errorDescription ?? "", perform: handleLastErrorChange)
            .confirmationDialog(L10n.Party.selfActionsTitle, isPresented: $showSelfActions) {
                selfActionsButtons
            }
            // v15:他人麦位 tap → UserCardPopup(sheet 化,对齐 H5 openUserCard)
            // 派对房主播端 tap 头像不跳 UserProfile(对齐 H5 主播端 route.path === '/liveSetting' 分支)
            // onSendGiftTap:关闭名片卡 + 拉起礼物面板(对齐 H5 partyStore.showPartyGiftPopup = true)
            // partyAdminContext:派对房 owner/admin 场景下嵌 admin action row
            .userCardSheet(
                item: Binding(
                    get: { userCardForUserId.map { UserCardPresentation(userId: $0) } },
                    set: { userCardForUserId = $0?.userId }
                ),
                onSendGiftTap: { _ in
                    // 先关名片卡再拉礼物面板;延迟 0.3s 避免同帧 dismiss+present 冲突(系统 sheet)
                    userCardForUserId = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showGiftPanel = true
                    }
                },
                partyAdminContext: partyAdminContextForCard
            )
            // 头像 tap 内置分派：party 房中 → 弹名片卡（走 userCardForUserId binding）
            .avatarUserCardPresenter { uid in userCardForUserId = uid }
            // v15：已在麦位点空位 → 切麦确认（对齐 H5 EnterSwitchPopup）
            .confirmationDialog(
                L10n.PartyRoom.switchSeatTitle,
                isPresented: switchSeatDialogPresented,
                titleVisibility: .visible
            ) {
                switchSeatDialogButtons
            }
            // v15：房主/房管点空位 → 管理动作 dialog（Take / Lock / Unlock）
            .confirmationDialog(
                L10n.PartyRoom.adminSeatActionsTitle,
                isPresented: adminSeatActionsPresented,
                titleVisibility: .visible
            ) {
                adminSeatActionsButtons
            }
            // v15：房主/房管点他人占用位 → 管理动作 dialog（Mute / Unmute / View Profile）
            .confirmationDialog(
                L10n.PartyRoom.otherSeatAdminActionsTitle,
                isPresented: otherSeatAdminActionsPresented,
                titleVisibility: .visible
            ) {
                otherSeatAdminActionsButtons
            }
            // v16.10：TapGesture 让点击外部区域收起键盘（对齐 LiveRoomView L459）。
            // TapGesture 与 Button/DragGesture 不同类别，不会挡住 seat/toolbar 按钮点击。
            .simultaneousGesture(
                TapGesture().onEnded {
                    if isInputFocused { isInputFocused = false }
                }
            )
            // v16.11：键盘 notification 订阅，同步 keyboardHeight 让 inputBar 上移
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
                guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
                withAnimation(.easeOut(duration: duration)) {
                    keyboardHeight = frame.height
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
                let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
                withAnimation(.easeOut(duration: duration)) {
                    keyboardHeight = 0
                }
            }
            // F-1a Task 22：PartyBattle UI 挂载点（避免 sceneBody 复杂度爆炸抽独立 modifier）
            .modifier(PartyBattleUIModifier(
                battleStore: battleStore,
                effectiveRoomId: store.roomInfo?.id ?? roomId,
                showInitiate: $showBattleInitiate,
                showForceEnd: $showBattleForceEnd,
                showCooldownToast: $showBattleCooldownToast,
                showRules: $showBattleRules
            ))
            .preferredColorScheme(.dark)
    }

    // MARK: - 全屏 stage

    private var stageContent: some View {
        ZStack {
            backgroundLayer
            contentColumn
            // v8：进房 loading overlay（对齐 H5 clickRoomItem 全屏 isSearchLoading 反馈）
            // 显示条件：preparing / entering 态；joined 或 ended 时消失让房内 UI 显现
            if store.roomState == .preparing || store.roomState == .entering {
                enterLoadingOverlay
            }
        }
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    /// 进房 loading：半透黑底 + ProgressView + 文案（对齐 PartySearchView loadingOverlay 模式）
    private var enterLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(.white).scaleEffect(1.3)
                Text(L10n.Party.enteringRoom)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
            }
        }
        .transition(.opacity)
    }

    /// 背景层：房主自定义大图（bigImgUrl 优先）→ H5 DEFAULT_BG 兜底 → partyRoomBg asset placeholder。
    ///
    /// **v17 移除静态降级**：直接把 bigImgUrl 按 URL 后缀分流给三种渲染器（image/mp4/svga），
    /// 与 H5 `room-bg.vue` `bgType` 逻辑一致；`imgUrl` 缩略图退化为**动态资源加载中的 placeholder**
    /// 覆盖层，就绪后透明度过渡消失（对齐 H5 `showPlaceholder` + `<Transition name="bg-placeholder">`）。
    ///
    /// **v16.3 真根因修复保留**：静态图路径下 CachedAsyncImage 需显式 `.frame + .clipped()` 约束到屏幕大小。
    /// **v16.7 保留**：UIScreen.main.bounds 锁定物理屏幕尺寸不受键盘避让影响。
    private var backgroundLayer: some View {
        let bg = store.currentRoomBackground
        let bigURL = firstNonEmpty(bg?.bigImgUrl, store.roomInfo?.bigImgUrl)
        let placeholderURL = firstNonEmpty(bg?.imgUrl, store.roomInfo?.bgImgUrl)
        let screenSize = UIScreen.main.bounds.size
        return ZStack {
            PartyRoomBackgroundView(
                bigImgURL: bigURL,
                placeholderURL: placeholderURL,
                size: screenSize
            )
            .ignoresSafeArea()

            Theme.Palette.partyRoomOverlay
                .frame(width: screenSize.width, height: screenSize.height)
                .ignoresSafeArea()
        }
        .frame(width: screenSize.width, height: screenSize.height)
    }

    private func firstNonEmpty(_ a: String?, _ b: String?) -> String? {
        if let a, !a.isEmpty { return a }
        if let b, !b.isEmpty { return b }
        return nil
    }

    /// 内容层（v16.11 版本）
    private var contentColumn: some View {
        VStack(spacing: 0) {
            anchorBar
                // v3：上内边距再 +6pt（8 → 16 → 22），与 status bar/dynamic island 更宽松呼吸位
                .padding(.top, 22)
            bigSeatRow
            smallSeatGrid
                .padding(.top, 12)
            chatArea
            Spacer(minLength: 0)
            inputBar
        }
        // v16.11：contentColumn 层阻止 SwiftUI 默认键盘避让
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    // MARK: - 顶部主播条

    private var anchorBar: some View {
        PartyRoomAnchorBar(
            roomName: store.roomInfo?.roomName ?? L10n.Party.defaultRoomName,
            roomId: store.roomInfo?.id ?? roomId,
            anchorAvatarURL: store.roomInfo?.roomAvatar,
            // v12：头像装饰框 URL（async 从 apiPartyGetUser 拉；对齐 H5 head-frame.vue）
            headFrameURL: store.ownerHeadFrameURL,
            wealthText: heatText,
            honorText: heatText,
            audienceCountText: "\(store.roomInfo?.onlineCount ?? 0)",
            isFollowing: store.isFollowingAnchor,
            // 用 isSelfRoomOwner（ownerId==myUserId）而非 selfRole == .owner：
            // 平台超管在他人房 selfRole 已被提权为 .owner（管理权限用），但**关注按钮显隐**
            // 属"是否房主本人"身份判定 —— 超管应能像普通用户一样关注房主
            isSelfRoom: store.isSelfRoomOwner,
            // v7.4.1 用户明示修正：房主本人 + admin 都可见"设置入口"；仅观众不显示
            // （Bug 1a 已修 selfRole 优先 selfSeat.roomRoleType 派生 → admin 权限实时生效）
            canManage: store.selfRole == .owner || store.selfRole == .admin,
            canStartPk: (store.selfRole == .owner || store.selfRole == .admin) && (store.roomInfo?.roomTempIdInt == 1),
            onFollowTap: handleFollowTap,
            onPkTap: handlePkTap,
            onAnnouncementTap: handleAnnouncementTap,
            onShareTap: handleShareTap,
            onManagementTap: handleManagementTap,
            onMoreTap: handleMoreTap,
            onRankTap: handleRankTap,
            onViewerTap: handleViewerTap
        )
    }

    /// F-1a Task 21：PK 入口点击（对齐 spec §6.2 · 三分支）
    /// - RUNNING 期 → 强制结束确认
    /// - COOLDOWN 期 → 提示 toast
    /// - 其他（idle / ended） → 发起弹窗
    private func handlePkTap() {
        guard battleStore.canStartPk || battleStore.isRunning || battleStore.isCoolingDown else {
            AppLogger.party.warning("[PartyRoom] pk tapped but !canStartPk (role/temp/switch not met)")
            return
        }
        if battleStore.isRunning {
            showBattleForceEnd = true
        } else if battleStore.isCoolingDown {
            showBattleCooldownToast = true
        } else {
            showBattleInitiate = true
        }
    }

    private func handleRankTap(_ kind: PartyRankKind) {
        AppLogger.party.notice("[PartyRoom] rank tapped kind=\(String(describing: kind), privacy: .public) (TODO F-milestone rank sheet)")
    }

    private var heatText: String {
        let heat = store.roomInfo?.heatValue ?? 0
        return PartyNumberFormat.compact(heat)
    }

    // MARK: - 大麦位（按模板动态：0/1/2/3/6+ 视频位）

    /// v12（对齐 H5 蓝本 livechat-h5/src/components/party/components/main-wrap.vue）：
    /// - `1`：外层 `.video-wrap h-180` 全宽容器（小屏 <380pt 高 156pt），内层视频 cell `w-186` 居中
    /// - `6`：`.video-wrap-6 grid grid-cols-3 gap-1 px-1`，每 cell `aspect-[6/5]`
    /// - `2/3/其他`：v11 沿用 HStack 均分屏宽，每 cell 9/16 竖屏
    /// - `0`：整行隐藏（纯语聊模板）
    @ViewBuilder
    private var bigSeatRow: some View {
        if bigSeats.count == 1 {
            singleBigSeat(bigSeats[0])
        } else if bigSeats.count == 6 {
            sixBigSeatGrid
        } else if !bigSeats.isEmpty {
            multiBigSeatRow
        }
    }

    /// v12：1 视频位模板 —— 对齐 H5 `.video-wrap h-180` 容器 + `w-186` 内层视频 cell 居中
    /// 小屏 (<380pt) 高降为 156pt（对齐 H5 `@media (max-width: 380px)`）
    private func singleBigSeat(_ seat: PartyRoomSeat) -> some View {
        let containerHeight: CGFloat = UIScreen.main.bounds.width < 380 ? 156 : 180
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            PartyRoomBigSeatCell(
                seat: seat,
                isSelf: isSelf(seat),
                isLocalCameraActive: store.isLocalCameraActive,
                camera: store.camera,
                engine: store.rtc,
                aspectRatio: nil
            )
            .frame(width: 186)
            .onTapGesture { handleSeatTap(seat) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: containerHeight)
    }

    /// v12：6 视频位模板 —— 3 列 × 2 行 grid（对齐 H5 `grid grid-cols-3 gap-1 px-1` + `aspect-[6/5]`）
    /// v12：6 视频位模板 —— 3 列 × 2 行 grid（对齐 H5 `grid grid-cols-3 gap-1 px-1` + `aspect-[6/5]`）
    /// **固定 height**：aspectRatio(.fit) 两维 flex 会被父 VStack 因键盘 padding 挤压 → 视频位缩小；
    /// 显式挂 `.frame(height:)` 让 seat 脱离 flex，键盘弹起时不受影响。
    private var sixBigSeatGrid: some View {
        LazyVGrid(columns: sixBigSeatColumns, spacing: 4) {
            ForEach(bigSeats, id: \.stableId) { seat in
                PartyRoomBigSeatCell(
                    seat: seat,
                    isSelf: isSelf(seat),
                    isLocalCameraActive: store.isLocalCameraActive,
                    camera: store.camera,
                    engine: store.rtc,
                    aspectRatio: 6.0 / 5.0
                )
                .onTapGesture { handleSeatTap(seat) }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: sixBigSeatGridHeight)
    }

    private var sixBigSeatColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
    }

    /// 6 视频位模板固定高度：cellW = (屏宽 - 2*4 hPadding - 2*4 colSpacing) / 3，cellH = cellW * 5/6，总高 = 2 行 + 1 rowSpacing
    private var sixBigSeatGridHeight: CGFloat {
        let screenW = UIScreen.main.bounds.width
        let cellW = (screenW - 16) / 3   // 16 = 2*4 padding + 2*4 col spacing
        let cellH = cellW * 5.0 / 6.0
        return cellH * 2 + 4   // 2 行 + 1 行 spacing
    }

    /// v11 沿用：2/3/其他 count → HStack 均分屏宽 + 每 cell 9/16 竖屏
    /// **固定 height**：同 sixBigSeatGrid 理由 —— aspectRatio(.fit) 会被键盘 padding 挤压。
    private var multiBigSeatRow: some View {
        HStack(spacing: Theme.Metric.partyRoomBigSeatGap) {
            ForEach(bigSeats, id: \.stableId) { seat in
                PartyRoomBigSeatCell(
                    seat: seat,
                    isSelf: isSelf(seat),
                    isLocalCameraActive: store.isLocalCameraActive,
                    camera: store.camera,
                    engine: store.rtc
                )
                .onTapGesture { handleSeatTap(seat) }
            }
        }
        .frame(height: multiBigSeatRowHeight)
        // v9：已按 seat.seatType 分组（video→大位，voice→小位）—— 对齐 H5 main-wrap.vue
    }

    /// 2/3/其他视频位模板固定高度：cellW = (屏宽 - (n-1)*gap) / n，cellH = cellW * 16/9（竖屏 9:16）
    private var multiBigSeatRowHeight: CGFloat {
        let n = CGFloat(max(bigSeats.count, 1))
        let gap = Theme.Metric.partyRoomBigSeatGap
        let cellW = (UIScreen.main.bounds.width - gap * (n - 1)) / n
        return cellW * 16.0 / 9.0
    }

    /// v9：按 seatType 分组（对齐 H5 main-wrap.vue slice(0, videoMicNum)）
    private var bigSeats: [PartyRoomSeat] {
        sortedSeatsCache.filter { $0.seatType == PartyRoomSeatType.video.rawValue }
    }

    // MARK: - 小麦位（按模板动态布局，v17 对齐 H5 main-wrap.vue 三分支）

    /// v17（对齐 H5 main-wrap.vue L326-349）：小麦位按 audioMicNum + 有无视频位分 3 布局分支
    /// - `smallSeats.count == 30 && bigSeats.isEmpty` → 6 列 5 行 grid + sm 变体（H5 L326）
    /// - `smallSeats.count <= 8 && bigSeats.isEmpty` → 前 n-4 + 后 4 底行分组（H5 L338）
    /// - 默认（≥10 或有视频位）→ 3/5 列 flex-wrap（对齐 H5 L332 flex-wrap w-68）
    @ViewBuilder
    private var smallSeatGrid: some View {
        if !smallSeats.isEmpty {
            Group {
                if smallSeats.count == 30 && bigSeats.isEmpty {
                    smallSeatGrid30
                } else if smallSeats.count <= 8 && bigSeats.isEmpty {
                    smallSeatSplitLayout
                } else {
                    smallSeatDefaultGrid
                }
            }
        }
    }

    /// v17（对齐 H5 `@media (max-width: 380px)` 音频位缩小）：小屏统一 sm 变体（35pt 头像 vs 46pt 默认）
    private var isSmallScreen: Bool {
        UIScreen.main.bounds.width < 380
    }

    /// v17：小麦位默认布局（≥10 麦位 或 有视频位）—— 现有 3/5 列 grid 保留 + sizeVariant 小屏自适应
    private var smallSeatDefaultGrid: some View {
        let variant: PartyRoomSmallSeatCell.SizeVariant = isSmallScreen ? .sm : .default
        return LazyVGrid(columns: smallSeatColumns, spacing: isSmallScreen ? 8 : 14) {
            ForEach(smallSeats, id: \.stableId) { seat in
                PartyRoomSmallSeatCell(
                    seat: seat,
                    isSpeaking: store.isSpeaking(seat: seat),
                    sizeVariant: variant
                )
                .onTapGesture { handleSeatTap(seat) }
            }
        }
        .padding(.horizontal, Theme.Metric.partyRoomScreenH)
    }

    /// v17：30 麦位纯语聊模板 —— 6 列 × 5 行 grid（对齐 H5 L326 `grid-cols-6 mx-2`）
    /// - 无视频位强制走 sm 变体（H5 `<AudioWrap size="sm">`）
    private var smallSeatGrid30: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 6)
        return LazyVGrid(columns: cols, spacing: 2) {
            ForEach(smallSeats, id: \.stableId) { seat in
                PartyRoomSmallSeatCell(
                    seat: seat,
                    isSpeaking: store.isSpeaking(seat: seat),
                    sizeVariant: .sm
                )
                .onTapGesture { handleSeatTap(seat) }
            }
        }
        .padding(.horizontal, 8)
    }

    /// v17：≤8 麦位纯语聊模板 —— 前 n-4 + 后 4 底行分组（对齐 H5 L338-349）
    /// - topCount < 4 → 上排居中；topCount = 4 → 上排 justify-between
    /// - 底排 4 个恒 justify-around（用 `.frame(maxWidth: .infinity)` 均分模拟）
    /// - 每 cell 固定宽 68pt（H5 `w-68`）
    private var smallSeatSplitLayout: some View {
        let n = smallSeats.count
        let topCount = max(n - 4, 0)
        let topSeats = Array(smallSeats.prefix(topCount))
        let bottomSeats = Array(smallSeats.suffix(min(4, n)))
        let variant: PartyRoomSmallSeatCell.SizeVariant = isSmallScreen ? .sm : .default
        let cellW: CGFloat = isSmallScreen ? 56 : 68
        return VStack(spacing: isSmallScreen ? 4 : 8) {
            if !topSeats.isEmpty {
                if topCount < 4 {
                    HStack(spacing: 20) {
                        ForEach(topSeats, id: \.stableId) { seat in
                            splitLayoutCell(seat, variant: variant, cellW: cellW)
                        }
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 0) {
                        ForEach(Array(topSeats.enumerated()), id: \.element.stableId) { idx, seat in
                            splitLayoutCell(seat, variant: variant, cellW: cellW)
                            if idx < topSeats.count - 1 { Spacer() }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            HStack(spacing: 0) {
                ForEach(bottomSeats, id: \.stableId) { seat in
                    splitLayoutCell(seat, variant: variant, cellW: cellW)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private func splitLayoutCell(_ seat: PartyRoomSeat,
                                 variant: PartyRoomSmallSeatCell.SizeVariant,
                                 cellW: CGFloat) -> some View {
        PartyRoomSmallSeatCell(
            seat: seat,
            isSpeaking: store.isSpeaking(seat: seat),
            sizeVariant: variant
        )
        .frame(width: cellW)
        .onTapGesture { handleSeatTap(seat) }
    }

    /// v11：列数按模板 smallSeats.count 自适应，避免 5 列固定在 3/6/9 麦模板下右侧留空。
    /// - ≤9 位（3/6/9 麦模板）：3 列（更方阵，行数 1/2/3）
    /// - ≥10 位（10/15/20 麦模板）：5 列（行数 2/3/4）
    private var smallSeatColumns: [GridItem] {
        let count = smallSeats.count <= 9 ? 3 : 5
        return Array(repeating: GridItem(.flexible(),
                                         spacing: Theme.Metric.partyRoomSmallSeatGap),
                     count: count)
    }

    /// v9：按 seatType 分组（对齐 H5 main-wrap.vue）；seatType==2 (voice) → 小位
    private var smallSeats: [PartyRoomSeat] {
        sortedSeatsCache.filter { $0.seatType == PartyRoomSeatType.voice.rawValue }
    }

    // MARK: - 聊天区

    private var chatArea: some View {
        PartyRoomChatArea(
            filter: $chatFilter,
            welcomeMessage: store.roomInfo?.greetingMessage ?? L10n.PartyRoom.welcomeFallback,
            chat: store.chat,
            lastGiftEvent: store.lastGiftEvent
        )
        .padding(.top, 6)
        // F-spec 派对房私 call 浮动开关按钮（房主 only；roomInfo 已加载才判定角色，未加载时兜底显示防误隐）
        // 位置：chatArea bottomTrailing —— 对齐设计稿"聊天区右下角靠近输入栏"（避免遮挡顶部欢迎语）
        .overlay(alignment: .bottomTrailing) {
            if shouldShowPrivateCallButton {
                PartyRoomPrivateCallButton(
                    isOn: privateCallOn,
                    selectedGiftIcon: store.partyCallGiftIcon,
                    selectedGiftPrice: store.partyCallGiftPrice,
                    isLoading: store.isTogglingPrivateCall,
                    onToggle: handlePartyCallToggle,
                    onTapGift: handlePartyCallGiftReselect
                )
                .padding(.trailing, 12)
                .padding(.bottom, 8)
            }
        }
    }

    /// 房主可见 + roomInfo 未加载完（selfRole 恒 .audience）时兜底显示，防止用户以为按钮被 guard 隐藏
    private var shouldShowPrivateCallButton: Bool {
        // 若 roomInfo 尚未加载 → 兜底显示（roomInfo 到达后 selfRole 精确判定）
        guard store.roomInfo != nil else { return true }
        return store.selfRole == .owner
    }

    // MARK: - F-spec 派对房私 call

    /// 派生态：从 `store.roomInfo.partyPrivateCallOpen` 单向流动（1029 广播 / setPrivateCall API 成功后回写自动同步）
    private var privateCallOn: Bool {
        store.roomInfo?.isPartyPrivateCallEnabled == true
    }

    /// 浮动按钮 tap handler（v5-需求 1：已有 giftId 复用不重选）：
    /// - 关 → 开：若 `roomInfo.partyCallGiftId` 已有 → 直接 API set enable=1 复用礼物（无需弹 sheet）
    ///           若无 → 拉起 `CommonGiftPanel.callGate` 让房主选礼物；confirm 后才 API set enable=1
    /// - 开 → 关：直接 `PartyStore.setPrivateCall(enable: false)`（视觉切换由 store 回写驱动）
    private func handlePartyCallToggle(_ next: Bool) {
        if next {
            if let existingGiftId = store.roomInfo?.partyCallGiftId, !existingGiftId.isEmpty {
                Task { await store.setPrivateCall(enable: true, giftId: existingGiftId) }
            } else {
                Task { @MainActor in
                    activeRoomTool = nil
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    activeRoomTool = .privateCall
                }
            }
        } else {
            Task { await store.setPrivateCall(enable: false, giftId: nil) }
        }
    }

    /// tap 按钮上的礼物 icon —— 无论开关状态都可以重选礼物（弹 gift panel）
    /// 复用与 `handlePartyCallToggle` 开启态相同的 sheet；confirm 后走 setPrivateCall(enable: true) 更新礼物
    private func handlePartyCallGiftReselect() {
        Task { @MainActor in
            activeRoomTool = nil
            try? await Task.sleep(nanoseconds: 200_000_000)
            activeRoomTool = .privateCall
        }
    }

    // MARK: - 底部输入 + 工具栏

    private var inputBar: some View {
        PartyRoomInputBar(
            text: $inputText,
            micOn: currentMicOn,
            // v12：emoji + mic 均以 isOnSeat 为门槛（完全对齐 H5 v-if=inPartyRole>-1）
            isOnSeat: store.selfSeat != nil,
            // v9：游戏按钮主播端不显示（对齐 H5 v-if=hasGameCenter，APP_USER_ROLE=2 主播端恒 false）
            showGameButton: false,
            // v12：消息未读徽章（对齐 H5 useUnreadMessageCount + van-badge）
            unreadCount: unreadBridge.totalUnread,
            // v16.10：focus 桥（focused 时收起右侧按钮，对齐 LiveRoomView pattern）
            focus: $isInputFocused,
            onSubmit: sendText,
            onEmojiTap: handleEmojiTap,
            onMessageTap: handleMessageTap,
            onMicTap: handleMicTap,
            onGameTap: handleGameTap,
            onToolMenuTap: handleToolMenuTap,
            onGiftTap: handleGiftTap
        )
        // v2：下内边距 20pt 让按钮行距 home indicator 更宽松呼吸位
        .padding(.bottom, 20)
        .background(
            Rectangle().fill(Color.black.opacity(0.15))
                .ignoresSafeArea(edges: .bottom)
        )
        // v16.11：键盘弹起时手动上移到键盘顶（配合 contentColumn `.ignoresSafeArea(.keyboard)` 使用）。
        // 背景层已用 UIScreen.main.bounds 绝对锁定（v16.7），padding 触发的 layout 重算不影响背景视觉。
        .padding(.bottom, keyboardHeight)
    }

    private var currentMicOn: Bool {
        guard let me = store.selfSeat else { return false }
        return (me.microphoneEnabled ?? 0) == 1 && (me.seatMicrophoneEnabled ?? 0) == 1
    }

    // MARK: - 视频邀请 alert

    private var invitePresented: Binding<Bool> {
        Binding(
            get: { store.pendingVideoSeatInvite != nil },
            set: { if !$0 { store.clearPendingVideoSeatInvite() } }
        )
    }

    @ViewBuilder private var inviteAlertButtons: some View {
        Button(L10n.Party.inviteAccept) { Task { await store.acceptVideoSeatInvite() } }
        Button(L10n.Party.inviteReject, role: .cancel) { Task { await store.rejectVideoSeatInvite() } }
    }

    @ViewBuilder private var inviteAlertMessage: some View {
        if let i = store.pendingVideoSeatInvite {
            Text(String(format: L10n.Party.inviteMessageFormat,
                        i.fromNickname ?? L10n.Party.defaultUser,
                        i.seatIndex))
        }
    }

    // MARK: - 自己麦位 sheet

    @ViewBuilder private var selfActionsButtons: some View {
        if let me = store.selfSeat {
            let micOn = (me.microphoneEnabled ?? 0) == 1 && (me.seatMicrophoneEnabled ?? 0) == 1
            Button(micOn ? L10n.Party.selfMicOff : L10n.Party.selfMicOn) {
                Task { await store.toggleSelfMedia(type: 1, enable: !micOn) }
            }
            if me.seatType == 1 {
                let camOn = (me.cameraEnabled ?? 0) == 1
                Button(camOn ? L10n.Party.selfCamOff : L10n.Party.selfCamOn) {
                    Task { await store.toggleSelfMedia(type: 2, enable: !camOn) }
                }
            }
            Button(L10n.Party.selfLeaveSeat, role: .destructive) {
                Task { await store.requestDownSeat() }
            }
        }
        Button(L10n.Party.cancel, role: .cancel) {}
    }

    // MARK: - Lifecycle 钩子（与原版语义一致）

    private func handleAppear() {
        // 长时间无操作自动离线：派对房中暂停监测（对齐 H5 isBusy 停 timer）
        AutoOfflineMonitor.shared.suspend()
        // 用户诉求 2026-07-09：进派对房 = 独占摄像头，若匹配中先静默关匹配
        if MatchStore.shared.state == .matching {
            Task { await MatchStore.shared.closeMatch(silent: true) }
        }
        // P2-10：onAppear 同步 cache 一次仅作为"上次会话残留"兜底
        sortedSeatsCache = store.seatList.sorted { ($0.seatIndex ?? 0) < ($1.seatIndex ?? 0) }
        // F 里程碑（spec §3.4 P0-2）：挂 CallStore observer 监听 PartyCall 通话结束触发 resumeParty
        // NSHashTable 多观察者数组，与 LiveStore attach 互不干扰
        CallStore.shared.attach(store)
        guard !didStartEnter else { return }
        didStartEnter = true
        Task { await ensureEntered() }
    }

    /// 双守卫防误退房：scenePhase != .background + 仅活跃态才 leave
    private func handleDisappear() {
        guard scenePhase != .background else { return }
        // F 里程碑：显式 detach（NSHashTable weak 会自动清，但显式调用是最佳实践）
        CallStore.shared.detach(store)
        AutoOfflineMonitor.shared.resume()
        if store.roomState == .joined || store.roomState == .entering {
            Task { await store.leaveRoom() }
        }
    }

    private func handleSeatListChange(_ newList: [PartyRoomSeat]) {
        sortedSeatsCache = newList.sorted { ($0.seatIndex ?? 0) < ($1.seatIndex ?? 0) }
    }

    private func handleLastErrorChange(_ msg: String) {
        showError = !msg.isEmpty
    }

    private func ensureEntered() async {
        if store.roomState == .joined, store.roomInfo?.id == roomId { return }
        if store.roomState != .idle, store.roomState != .ended {
            await store.forceLeaveRoom(.userRequest)
        }
        // v8：密码房带 password 参数（对齐 PartyAPI.enterRoom 已有 password 字段）
        await store.enterRoom(roomId: roomId, password: password)
    }

    // MARK: - 麦位点击分流

    private func isSelf(_ seat: PartyRoomSeat) -> Bool {
        guard let me = store.myUserIdString else { return false }
        return seat.userId == me
    }

    /// v15：麦位点击分流（对齐 H5 g-agora-party.vue `joinOrOutMic` 完整语义）。
    ///
    /// 分支优先级（从上到下）：
    /// 1. 自己麦位 → showSelfActions（sheet: mic/cam/leave）
    /// 2. 他人占用麦位 → userCard（弹 UserCardPopup）
    /// 3. **管理员（房主/房管）点空位 → adminSeatActionsTarget（Take/Lock/Unlock dialog）**
    /// 4. 空锁麦位 (lockFlag=1) → toast "The seat is locked"（非管理员）
    /// 5. 空视频位 + 非管理员 → toast "Requires invitation..."
    /// 6. 空语音位 + 已在其他麦位 → switchSeatPendingTarget（切麦确认）
    /// 7. 空语音位 + 未在任何麦位 → 直接 onSeat
    private func handleSeatTap(_ seat: PartyRoomSeat) {
        if isSelf(seat) {
            showSelfActions = true
            return
        }
        let isManager = store.selfRole == .owner || store.selfRole == .admin
        if seat.occupied, let uid = seat.userId, !uid.isEmpty {
            // v15：房主/房管点他人占用位 → 管理 dialog（Mute/Unmute + View Profile）
            // 非管理员 → 直接 UserCard（对齐 H5 openUserCard）
            if isManager {
                otherSeatAdminActionsTarget = seat
            } else {
                userCardForUserId = uid
            }
            return
        }
        guard let idx = seat.seatIndex else { return }
        if isManager {
            adminSeatActionsTarget = seat
            return
        }
        if (seat.lockFlag ?? 0) == 1 {
            stubToolToast = L10n.PartyRoom.seatLockedToast
            return
        }
        if seat.seatType == PartyRoomSeatType.video.rawValue {
            stubToolToast = L10n.PartyRoom.videoSeatNeedsInviteToast
            return
        }
        // 空语音位（非管理员）
        if store.selfSeat != nil {
            switchSeatPendingTarget = seat
            return
        }
        // 对齐安卓 PartyRoomActivity §3.2：开关开 + 非特权 → 走"申请上麦"流程；否则直接上麦
        // isManager 已在前面分支处理并 return；这里仅剩非特权观众
        if store.micApplicationSwitchOn {
            Task { await store.applyMic(seatIndex: idx) }
            return
        }
        Task { await store.requestOnSeat(seatIndex: idx) }
    }

    // MARK: - v15 UserCard sheet(sheet 化后 helper computed 已删,挂载走 §.userCardSheet 一行 modifier)

    /// 名片卡内嵌 admin action row 上下文 —— 派生自 store 当前态 + 当前查看的 userCardForUserId。
    /// - 我方非 owner/admin → nil(admin row 隐藏)
    /// - 目标是我自己 → nil(不能对自己操作)
    /// - 其他场景返回 PartyAdminContext,UserCardPopup 内 canShowAdminActions 再过滤(目标房主/角色差异等)
    private var partyAdminContextForCard: PartyAdminContext? {
        guard let uid = userCardForUserId else { return nil }
        guard store.selfRole == .owner || store.selfRole == .admin else { return nil }
        if let mineUidInt = SessionStore.shared.user?.userId, uid == String(mineUidInt) { return nil }

        let targetSeat = store.seatList.first { $0.userId == uid }
        let targetRole = targetSeat?.typedRole

        return PartyAdminContext(
            selfRole: store.selfRole,
            targetSeat: targetSeat,
            targetRoleType: targetRole,
            roomId: store.roomInfo?.id ?? roomId,
            kickOutHours: 24,   // TODO: 从 partyBaseConfig.kickOutInterval 派生(base config 未接入前默认 24h)
            onKickFromMic: { targetUserId, seatIndex in
                Task { await store.requestKickFromMic(seatIndex: seatIndex, targetUserId: targetUserId) }
                userCardForUserId = nil
            },
            onToggleMute: { seatIndex, mute in
                Task { await store.requestProhibitSeat(seatIndex: seatIndex, mute: mute) }
                // 不关闭 sheet:mute 后等 IM 1008 广播 → seat.seatMicrophoneEnabled 更新
            },
            onSetAdmin: { targetUserId, add in
                Task { await store.requestSetAdmin(userId: targetUserId, add: add) }
                userCardForUserId = nil
            },
            onKickOutRoom: { seatIndex, targetUserId, banType in
                Task { await store.requestKickOutRoom(seatIndex: seatIndex, targetUserId: targetUserId, banType: banType) }
                userCardForUserId = nil
            }
        )
    }

    // MARK: - v15 切麦确认

    private var switchSeatDialogPresented: Binding<Bool> {
        Binding(
            get: { switchSeatPendingTarget != nil },
            set: { if !$0 { switchSeatPendingTarget = nil } }
        )
    }

    @ViewBuilder private var switchSeatDialogButtons: some View {
        Button(L10n.PartyRoom.switchSeatConfirm) {
            guard let target = switchSeatPendingTarget,
                  let idx = target.seatIndex,
                  let type = target.seatType else { return }
            switchSeatPendingTarget = nil
            Task { await store.requestExchangeSeat(targetSeatIndex: idx, targetSeatType: type) }
        }
        Button(L10n.Party.cancel, role: .cancel) { switchSeatPendingTarget = nil }
    }

    // MARK: - v15 房主/房管空位管理

    private var adminSeatActionsPresented: Binding<Bool> {
        Binding(
            get: { adminSeatActionsTarget != nil },
            set: { if !$0 { adminSeatActionsTarget = nil } }
        )
    }

    /// 房主/房管点空位的动作 sheet：
    /// - 未在任何麦位 → Take Seat（视频位管理员可自上，绕过普通用户"需邀请"限制）
    /// - 已在其他麦位 → Switch Here（走切麦）
    /// - Lock/Unlock（按 seat.lockFlag 动态切换文案）
    @ViewBuilder private var adminSeatActionsButtons: some View {
        if let seat = adminSeatActionsTarget, let idx = seat.seatIndex {
            let locked = (seat.lockFlag ?? 0) == 1
            let type = seat.seatType ?? PartyRoomSeatType.voice.rawValue
            // Take / Switch 按钮（锁麦位不给 Take 入口，需要先 Unlock）
            if !locked {
                if store.selfSeat == nil {
                    Button(L10n.PartyRoom.adminActionTake) {
                        adminSeatActionsTarget = nil
                        Task { await store.requestOnSeat(seatIndex: idx) }
                    }
                } else {
                    Button(L10n.PartyRoom.adminActionSwitchHere) {
                        adminSeatActionsTarget = nil
                        Task { await store.requestExchangeSeat(targetSeatIndex: idx, targetSeatType: type) }
                    }
                }
            }
            // Lock / Unlock
            Button(locked ? L10n.PartyRoom.adminActionUnlock : L10n.PartyRoom.adminActionLock) {
                adminSeatActionsTarget = nil
                Task { await store.requestLockSeat(seatIndex: idx, lock: !locked) }
            }
        }
        Button(L10n.Party.cancel, role: .cancel) { adminSeatActionsTarget = nil }
    }

    // MARK: - v15 房主/房管他人占用位管理

    private var otherSeatAdminActionsPresented: Binding<Bool> {
        Binding(
            get: { otherSeatAdminActionsTarget != nil },
            set: { if !$0 { otherSeatAdminActionsTarget = nil } }
        )
    }

    /// 房主/房管点他人占用位的动作 dialog：
    /// - **Mute/Unmute（仅语音麦位）**：调 prohibitSeat 切 seatMicrophoneEnabled（对齐 H5 my-mic-tool `!nowSeatIsVideo` 条件）
    /// - **View Profile**：dismiss dialog + 弹 UserCardPopup（保留原查看用户资料能力）
    /// - Kick / Manager 等入口留 Phase 2（需 UserCard 内做，跨场景组件不改）
    @ViewBuilder private var otherSeatAdminActionsButtons: some View {
        if let seat = otherSeatAdminActionsTarget, let idx = seat.seatIndex {
            // Mute/Unmute 仅语音麦位（对齐 H5 v-if=!nowSeatIsVideo）
            if seat.seatType == PartyRoomSeatType.voice.rawValue {
                let muted = (seat.seatMicrophoneEnabled ?? 1) == 0
                Button(muted ? L10n.PartyRoom.adminActionUnmute : L10n.PartyRoom.adminActionMute) {
                    otherSeatAdminActionsTarget = nil
                    Task { await store.requestProhibitSeat(seatIndex: idx, mute: !muted) }
                }
            }
            // View Profile - dismiss + open UserCard
            if let uid = seat.userId, !uid.isEmpty {
                Button(L10n.PartyRoom.adminActionViewProfile) {
                    otherSeatAdminActionsTarget = nil
                    // iOS 16 sheet/dialog race 规避：延一帧再挂 UserCard overlay
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        userCardForUserId = uid
                    }
                }
            }
        }
        Button(L10n.Party.cancel, role: .cancel) { otherSeatAdminActionsTarget = nil }
    }

    // MARK: - 发送公屏

    /// v16.10：内嵌 TextField 发送（对齐 LiveRoomView L400+ onSend）
    /// 成功后清空 inputText + 主动失焦收起键盘（LiveRoomView L417 `inputText = ""` 后键盘继续保持，Party 也保持同款）
    private func sendText() {
        let txt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !txt.isEmpty, store.roomState == .joined else { return }
        store.chat.sendText(txt)
        inputText = ""
    }

    // MARK: - 顶部工具栏 handler

    /// v16：关注/取关房主（对齐 H5 header-wrap.vue userStore.followOrNo）
    /// 走 `store.toggleFollowAnchor()` 统一维护 `isFollowingAnchor`；
    /// **成功 toast 由 [FollowListService.followUser] service 层触发 [AppToastCenter] 全局弹出**，
    /// 本 view 不再本地弹（避免与全局 toast 重复展示）。
    /// 进房关注态由 room/enter 接口 `isFollowOwner` 字段初始化，退出重进保持一致。
    private func handleFollowTap() {
        // 用 isSelfRoomOwner 而非 selfRole == .owner：
        // 平台超管 selfRole 被提权为 .owner，但可关注房主 —— 参见 isSelfRoom 相同逻辑
        guard !store.isSelfRoomOwner else {
            AppLogger.party.notice("[PartyRoom] follow: is owner self; skip")
            return
        }
        Task { @MainActor in
            _ = await store.toggleFollowAnchor()
        }
    }

    /// v9：公告只读 sheet（对齐 H5 announcement-popup.vue，MVP 只读）
    /// 房主/房管编辑权限 F 期补（PartyAPI.setAnnouncement 端点 + 编辑态 UI）。
    private func handleAnnouncementTap() {
        showAnnouncement = true
    }

    private func handleShareTap() {
        // F 期便利功能（2026-07-17）：ShareLink 深链分享 —— 用 UIActivityViewController 承接系统分享面板。
        // H5 蓝本 share-list-wrap.vue 是"分享到 IM 好友"（走 NIM 自定义消息），iOS 主播端首版做**站外**
        // 系统分享出口（wechat/whatsapp/复制），IM 好友转发暂不做（差异文档 §2.3：私聊仅限观众→主播场景）。
        // 后端若下发短链 API（`apiGetShareUrl`）时可替换 partyShareBaseURL 常量。
        guard let rid = store.roomInfo?.id, !rid.isEmpty else {
            AppLogger.party.notice("[PartyRoom] share tapped but roomId missing")
            return
        }
        let url = "\(AppConfig.partyShareBaseURL)\(rid)"
        let text = String(format: L10n.PartyRoom.shareMessageFormat, url)
        shareItems = [text]
        AppLogger.party.info("[PartyRoom] share tapped roomId=\(rid, privacy: .public)")
    }
    private func handleManagementTap() {
        // v7.4.1：房主 + admin 都能打开 tools sheet（对齐 anchorBar canManage 判定；观众依然拦下）
        // Bug 1a 已修 selfRole 优先从 selfSeat.roomRoleType 派生 → admin 权限实时生效
        if store.selfRole == .owner || store.selfRole == .admin {
            activeRoomTool = .tools
        } else {
            AppLogger.party.notice("[PartyRoom] management tapped by audience; ignored")
        }
    }

    /// v8.1 房间工具 sheet（enum-driven 单 sheet 切换）：
    /// - .tools → PartyRoomToolsSheet（3 列网格）
    /// - .settings → 房主设置编辑页
    /// - .blocklist → 黑名单页（F 期实现，MVP stub）
    @ViewBuilder
    private func roomToolContent(kind: PartyRoomToolSheetKind) -> some View {
        switch kind {
        case .tools:
            PartyRoomToolsSheet(
                isOwner: store.selfRole == .owner,
                // 平台超管在 selfRole 层已提权为 .owner（PartyStore.selfRole 首判 isPlatformAdmin），此参数保留
                // 为语义冗余安全网 —— MC Seat `if isOwner || isPlatformAdmin` 条件下双重命中
                isPlatformAdmin: store.roomInfo?.isPlatformAdmin ?? false,
                onTapSettings: {
                    // 用 Task.sleep 一帧规避 iOS 16 sheet 切换 race
                    Task { @MainActor in
                        activeRoomTool = nil
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        activeRoomTool = .settings
                    }
                },
                onTapBlocklist: {
                    Task { @MainActor in
                        activeRoomTool = nil
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        activeRoomTool = .blocklist
                    }
                },
                onTapRoomMode: {
                    // E v2 §1：切 Room Mode 模板 grid sheet
                    Task { @MainActor in
                        activeRoomTool = nil
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        activeRoomTool = .roomMode
                    }
                },
                onTapMicApplication: {
                    // E v2 §2：切 Mic Application 申请列表 sheet
                    Task { @MainActor in
                        activeRoomTool = nil
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        activeRoomTool = .micApplicationList
                    }
                },
                onTapLockRoom: {
                    // spec §3.4：已锁态直接调 unlockRoom（无弹窗）；未锁态才弹密码输入 sheet
                    if store.roomInfo?.lockFlag == 1 {
                        Task { @MainActor in
                            activeRoomTool = nil
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            await store.unlockRoom()
                        }
                    } else {
                        Task { @MainActor in
                            activeRoomTool = nil
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            activeRoomTool = .lockRoom
                        }
                    }
                },
                onTapMCSeat: {
                    // E-spec MC Seat：关 tools sheet + 350ms 后打开 PartyMCSeatSheet
                    Task { @MainActor in
                        activeRoomTool = nil
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        activeRoomTool = .mcSeat
                    }
                },
                onTapStub: { label in
                    // 关 sheet + 顶部 toast
                    Task { @MainActor in
                        activeRoomTool = nil
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        stubToolToast = "\(label): \(L10n.Party.toolComingSoon)"
                    }
                }
            )
            .presentationDetents([.medium])
        case .settings:
            NavigationStack {
                PartyRoomSettingsView(
                    store: PartyRoomSettingsStore(
                        roomId: store.roomInfo?.id ?? roomId,
                        roomName: store.roomInfo?.roomName ?? "",
                        tagline: store.roomInfo?.greetingMessage ?? "",
                        languageCode: store.roomInfo?.roomLanguage ?? "",
                        avatarUrl: store.roomInfo?.roomAvatar,
                        backgroundId: nil
                    ),
                    onSaved: { snapshot in
                        // v8.2：同步 PartyStore.roomInfo → 顶栏立即刷新
                        store.applyRoomSettingsChanges(
                            roomName: snapshot.roomName,
                            roomAvatar: snapshot.avatarUrl,
                            greetingMessage: snapshot.tagline,
                            roomLanguage: snapshot.languageCode
                        )
                        activeRoomTool = nil
                    }
                )
            }
            .preferredColorScheme(.dark)
        case .blocklist:
            NavigationStack {
                PartyBlocklistSheet(store: store)
            }
            .preferredColorScheme(.dark)
            .presentationDetents([.medium, .large])
        case .roomMode:
            // E v2 §1 + §3 Sheet Mount Hoist：Room Mode 模板 grid → onConfirmRequest 上抛 → 切 .roomModeConfirm
            NavigationStack {
                PartyRoomModeSheet(
                    store: store,
                    onConfirmRequest: { tempId in
                        Task { @MainActor in
                            activeRoomTool = nil
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            pendingRoomModeTempId = tempId
                            activeRoomTool = .roomModeConfirm
                        }
                    }
                )
            }
            .preferredColorScheme(.dark)
        case .roomModeConfirm:
            // E v2 §1：二次确认 → onConfirm 调 store.switchRoomMode 完成切模板
            PartyRoomModeConfirmSheet(
                tempId: pendingRoomModeTempId ?? 0,
                tempName: nil,
                onCancel: {
                    activeRoomTool = nil
                    pendingRoomModeTempId = nil
                },
                onConfirm: {
                    guard let t = pendingRoomModeTempId else {
                        activeRoomTool = nil
                        return
                    }
                    Task {
                        let before = store.lastError
                        await store.switchRoomMode(to: t)
                        // spec §4 R4：API 失败 → 弹窗保持 + lastError alert 展示；成功才关
                        let apiFailed = (store.lastError != nil) && (store.lastError?.errorDescription != before?.errorDescription)
                        await MainActor.run {
                            if !apiFailed {
                                activeRoomTool = nil
                                pendingRoomModeTempId = nil
                            }
                        }
                    }
                }
            )
            .presentationDetents([.height(200)])
        case .micApplicationList:
            NavigationStack {
                PartyMicApplicationSheet(store: store, onTapSwitchToggle: {
                    // 先判 autoEnter*Application flag：首次切换弹协议确认；二次直接调 API
                    let willEnable = !store.micApplicationSwitchOn
                    let alreadyConfirmed = willEnable ? store.autoEnterOnApplication : store.autoEnterOffApplication
                    if alreadyConfirmed {
                        Task { await store.toggleMicApplicationSwitch(enable: willEnable) }
                        return
                    }
                    Task { @MainActor in
                        activeRoomTool = nil
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        activeRoomTool = .micApplicationSwitchConfirm
                    }
                })
            }
            .preferredColorScheme(.dark)
            .presentationDetents([.medium, .large])
        case .micApplicationSwitchConfirm:
            // E v2 §2 A4：首次切换 Mic Application 开关的协议确认（confirm 后本地 flag 置 true）
            PartyMicApplicationSwitchConfirmSheet(
                enable: !store.micApplicationSwitchOn,
                onCancel: { activeRoomTool = nil },
                onConfirm: {
                    let willEnable = !store.micApplicationSwitchOn
                    Task {
                        await store.toggleMicApplicationSwitch(enable: willEnable)
                        await MainActor.run {
                            if willEnable {
                                store.autoEnterOnApplication = true
                            } else {
                                store.autoEnterOffApplication = true
                            }
                            activeRoomTool = nil
                        }
                    }
                }
            )
            .presentationDetents([.height(220)])
        case .lockRoom:
            NavigationStack {
                PartyLockRoomSheet(store: store)
            }
            .presentationDetents([.height(320)])
            .preferredColorScheme(.dark)
        case .mcSeat:
            NavigationStack { PartyMCSeatSheet(store: store) }
                .presentationDetents([.medium, .large])
                .preferredColorScheme(.dark)
        case .privateCall:
            // F-spec §5.1 v5：房主开开关时拉直播设置同款礼物面板（CommonGiftPanel.callGate + 蓝钻）
            // 用户 confirm 选中礼物 → 调 PartyAPI.updatePartyPrivateCall(enable=1, giftId) → 关 sheet
            // 用户 confirm 但 gift=nil → 视为放弃，不 API，仅关 sheet（对齐 callGate "移除" 语义）
            // v5-需求 3：关闭态时 confirm 按钮文案改为 "Open private call" 提示"点确认即开启"
            // v5-需求 4：onConfirm 提取 giftIcon/giftPrice 传给 store 立即更新按钮预览（不等下次 enterRoom 回写）
            CommonGiftPanel(config: .callGate(
                minPrice: 0,
                initialSelection: nil,
                onConfirm: { [store] gift in
                    if let gift {
                        let icon = gift.giftSmallImg.isEmpty ? gift.giftImg : gift.giftSmallImg
                        let price = Int(exactly: gift.giftPrice)
                        Task { @MainActor in
                            await store.setPrivateCall(
                                enable: true,
                                giftId: String(gift.id),
                                giftIcon: icon,
                                giftPrice: price
                            )
                            activeRoomTool = nil
                        }
                    } else {
                        activeRoomTool = nil
                    }
                },
                useBlueDiamond: true,
                confirmLabel: privateCallOn ? nil : L10n.Party.privateCallOpenConfirmLabel
            ))
            .presentationDetents([.medium, .large])
            .preferredColorScheme(.dark)
        }
    }

    /// v8 房主设置 sheet（保留 legacy 路径，v8.1 主入口走 activeRoomTool 单 sheet）
    @ViewBuilder
    private var settingsSheet: some View {
        NavigationStack {
            PartyRoomSettingsView(
                store: PartyRoomSettingsStore(
                    roomId: store.roomInfo?.id ?? roomId,
                    roomName: store.roomInfo?.roomName ?? "",
                    tagline: store.roomInfo?.greetingMessage ?? "",
                    languageCode: store.roomInfo?.roomLanguage ?? "",
                    avatarUrl: store.roomInfo?.roomAvatar,
                    backgroundId: nil
                ),
                onSaved: { snapshot in
                    store.applyRoomSettingsChanges(
                        roomName: snapshot.roomName,
                        roomAvatar: snapshot.avatarUrl,
                        greetingMessage: snapshot.tagline,
                        roomLanguage: snapshot.languageCode
                    )
                    showSettings = false
                }
            )
        }
        .preferredColorScheme(.dark)
    }
    /// v9：更多菜单（对齐 H5 more-tool-popup.vue Minimize + Exit 二选一）
    /// 目前 Minimize（PiP）留 F 期，MVP 只提供 Exit + Cancel。
    private func handleMoreTap() {
        showMoreActions = true
    }

    private func handleHeatTap() {
        // TODO(F 里程碑)：新建 PartyRoomRankSheet 展示房间热度/贡献榜（H5 蓝本 room-rank.vue tab=wealthRank/honorRank）；
        // 数据源 apiPartyContributionRank / apiPartyHonorRank 需 H5 二次校验字面 path。
        AppLogger.party.notice("[PartyRoom] heat tapped (TODO F)")
    }
    private func handleViewerTap() {
        // TODO(F 里程碑)：新建 PartyRoomViewerListSheet 复用 UserWeeklyRankSheetView pattern；
        // 数据源直接消费 store.roomInfo.onlineUserList，cell tap → UserCardPopup（H-0 已就绪）；
        // onlineCount==0 时按 H5 语义应隐藏按钮（当前 UX 常显）
        AppLogger.party.notice("[PartyRoom] viewer list tapped (TODO F)")
    }
    /// F 里程碑（2026-07-17）表情面板入口（对齐 H5 party-expression-popup.vue showEmojiPopup=true）。
    /// 上麦门槛已在 `PartyRoomInputBar.emojiButton` `isOnSeat` opacity/hitTest 门控 · 此处触发条件即已上麦。
    private func handleEmojiTap() {
        showExpressionPanel = true
    }
    /// v12：消息按钮（对齐 H5 footer-wrap.vue onClickMsgBtn → partyStore.openPartyMessage()）
    /// A 档接入：复用 Live 侧 ConversationSheetContent 半屏消息列表
    private func handleMessageTap() {
        showMessageSheet = true
    }

    /// v12：更多工具菜单（对齐 H5 party-tool-menu.vue PK/Lucky Number/Room Mute 汇总）
    /// B 档 stub：弹 confirmationDialog 汇总 3 入口；接口 F/G 期接
    /// TODO(F/G 里程碑)：
    ///   - Room Mute → PartyRTCEngine.setMuteAllRemoteAudio(Bool) + Store isRoomMuted
    ///   - Start PK → G 期；roomTempId===1 && battleStore.isFunctionEnabled 双门槛
    ///   - Lucky Number → F 期；usePartyLuckyNumber.generate() + 配置面板
    private func handleToolMenuTap() {
        showToolMenu = true
    }

    /// 麦按钮：若已在麦，直接切自己 mic；未上麦不响应
    private func handleMicTap() {
        guard let me = store.selfSeat else { return }
        let micOn = (me.microphoneEnabled ?? 0) == 1 && (me.seatMicrophoneEnabled ?? 0) == 1
        Task { await store.toggleSelfMedia(type: 1, enable: !micOn) }
    }
    private func handleGameTap() {
        // v9：H5 主播端不显示此按钮（APP_USER_ROLE=2 v-if=hasGameCenter 拦截）；
        // showGameButton: false 已在 inputBar 隐藏。此 handler 保留兜底 log
        // TODO(J 里程碑)：若产品要求主播端也有游戏入口，走 H5 iframe pattern
        AppLogger.party.notice("[PartyRoom] game tapped (should be hidden on anchor-end)")
    }
    /// H-5：底部礼物 icon tap → 拉起礼物面板（对齐 H5 party-gift-popup.vue showPartyGiftPopup=true）。
    /// 面板内首次 `.onAppear` 触发 `PartyGiftDataSource.load` → sapi `getPartyRoomGift` 拉列表。
    private func handleGiftTap() {
        showGiftPanel = true
    }

    /// H-5：礼物面板 sheet 内容 —— CommonGiftPanel + `.partySend` 工厂配置。
    /// receivers 由 [PartyGiftPanelBridge.makeReceiversConfig] 从 seatList 派生（过滤空 yxAccid/自己）。
    ///
    /// **主播端无充值功能**：`onRechargeRequested` 用 factory 默认空 closure，
    /// balance 胶囊 tap 走 Footer 内 `store.refreshBalance()`（刷新余额）。
    @ViewBuilder
    private var giftPanelSheet: some View {
        let receivers = PartyGiftPanelBridge.makeReceiversConfig(
            seatList: store.seatList,
            selfYxAccid: SessionStore.shared.user?.yxAccid
        )
        let config = CommonGiftPanelConfig.partySend(
            roomId: store.roomInfo?.id ?? roomId,
            receivers: receivers,
            onSend: { _, _, _ in
                giftSentToast = L10n.giftPickerSentToast
            }
        )
        CommonGiftPanel(config: config)
            // 高度 40%（对齐产品需求 · 由 [.height(600)] 改 fraction）
            .presentationDetents([.fraction(0.4)])
            .preferredColorScheme(.dark)
    }

    // MARK: - v9 sheets & action dialogs

    /// 公告 sheet（对齐 H5 announcement-popup.vue）。
    /// F 期房主管理批（2026-07-17）：房主/平台超管可切编辑态修改 greetingMessage 并 save。
    /// 权限判定：`store.selfRole == .owner`（平台超管已在 selfRole 层提权，见 PartyRoomInfo.selfRoleType）。
    @ViewBuilder
    private var announcementSheet: some View {
        NavigationStack {
            let currentText = store.roomInfo?.greetingMessage ?? ""
            let canEdit = store.selfRole == .owner
            ScrollView {
                if isEditingAnnouncement {
                    // 编辑态：TextEditor + placeholder overlay（对齐 H5 form 输入体感）
                    ZStack(alignment: .topLeading) {
                        if announcementDraft.isEmpty {
                            Text(L10n.PartyRoom.announcementPlaceholder)
                                .font(.system(size: 15))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $announcementDraft)
                            .font(.system(size: 15))
                            .foregroundColor(.primary)
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(minHeight: 160)
                            .disabled(isSavingAnnouncement)
                    }
                } else if currentText.isEmpty {
                    Text(L10n.PartyRoom.announcementEmpty)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    Text(currentText)
                        .font(.system(size: 15))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .navigationTitle(L10n.PartyRoom.announcementTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isEditingAnnouncement {
                    // 编辑态：leading=Cancel / trailing=Save
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(L10n.PartyRoom.announcementCancel) {
                            isEditingAnnouncement = false
                            announcementDraft = currentText
                        }
                        .disabled(isSavingAnnouncement)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if isSavingAnnouncement {
                            ProgressView()
                        } else {
                            Button(L10n.PartyRoom.announcementSave) { performSaveAnnouncement() }
                        }
                    }
                } else if canEdit {
                    // 只读态且是房主/超管：显示 Edit / Close
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(L10n.PartyRoom.announcementClose) { showAnnouncement = false }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(L10n.PartyRoom.announcementEdit) {
                            announcementDraft = currentText
                            isEditingAnnouncement = true
                        }
                    }
                } else {
                    // 只读态且非房主：只有 Close
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(L10n.PartyRoom.announcementClose) { showAnnouncement = false }
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
        .onChange(of: showAnnouncement) { newVal in
            // dismiss sheet 时同时退出编辑态，避免下次打开残留 dirty draft
            if !newVal {
                isEditingAnnouncement = false
                announcementDraft = ""
            }
        }
    }

    /// F 期房主管理批：Save 通告。成功 toast + 关编辑态 + 关 sheet；失败 toast 保留编辑态供重试。
    private func performSaveAnnouncement() {
        guard !isSavingAnnouncement else { return }
        isSavingAnnouncement = true
        let draft = announcementDraft
        Task { @MainActor in
            let ok = await store.updateAnnouncement(text: draft)
            isSavingAnnouncement = false
            if ok {
                AppToastCenter.shared.show(L10n.PartyRoom.announcementSaveSuccess)
                isEditingAnnouncement = false
                showAnnouncement = false
            } else {
                AppToastCenter.shared.show(L10n.PartyRoom.announcementSaveFailed)
            }
        }
    }

    /// 更多菜单 action sheet（对齐 H5 more-tool-popup.vue：Minimize + Exit）
    /// Minimize (PiP) 留 F 期，MVP 只提供 Exit + Cancel。
    @ViewBuilder
    private var moreActionsButtons: some View {
        Button(L10n.PartyRoom.moreMenuLeave, role: .destructive) {
            // 退房逻辑（HTTP + RTC + Chat）后台跑；立即 dismiss 让用户感知不到接口延迟。
            // leaveRoom 内同步转 roomState = .leaving，handleDisappear guard 会拒绝重入，无重复请求。
            Task { await store.leaveRoom() }
            dismiss()
        }
        Button(L10n.Party.cancel, role: .cancel) {}
    }

    // MARK: - v13 底部工具栏覆盖层（message / toolMenu；v13 已删 apply）

    /// 把新加的 footer overlay 挂在 stageContent 上，让 sceneBody 保持轻量
    /// 避免 modifier chain 累加触发 SwiftUI type-check timeout（rule swiftui-body-type-check-timeout §4）
    private var stageContentWithFooterOverlays: some View {
        stageContent
            .sheet(isPresented: $showMessageSheet) { messageSheetContent.giftPanelSheetBackground() }
            .confirmationDialog(L10n.PartyRoom.toolMenuTitle,
                                isPresented: $showToolMenu,
                                titleVisibility: .visible) { toolMenuButtons }
    }

    /// 消息半屏 sheet（复用 Live 侧 ConversationSheetContent 公共组件）
    /// v13：高度对齐 LiveRoomView.messageSheetContent（fraction 0.55 + drag indicator）
    /// 内层 sheet-over-sheet 私聊 detent 由 ConversationSheetContent 内部 chatSheetDetent 管理，键盘弹起自动切 .large
    @ViewBuilder
    private var messageSheetContent: some View {
        ConversationSheetContent(
            store: .shared,
            selfYxAccId: SessionStore.shared.user?.yxAccid ?? "",
            onClose: { showMessageSheet = false }
        )
        .presentationDetents([.fraction(0.55)])
        .presentationDragIndicator(.visible)
    }

    /// 更多工具菜单 dialog（B 档 stub）—— 汇总 PK / Lucky Number / Room Mute 三入口 + Cancel
    @ViewBuilder
    private var toolMenuButtons: some View {
        // TODO(G 里程碑)：Start PK —— roomTempId===1 && battleStore.isFunctionEnabled 双门槛
        Button(L10n.PartyRoom.toolMenuStartPk) {
            AppLogger.party.notice("[PartyRoom] toolMenu.startPk tapped (TODO G)")
        }
        // TODO(F 里程碑)：Lucky Number generate/settings —— usePartyLuckyNumber.generate() + 配置面板
        Button(L10n.PartyRoom.toolMenuLuckyNumber) {
            AppLogger.party.notice("[PartyRoom] toolMenu.luckyNumber tapped (TODO F)")
        }
        // F 期便利功能（2026-07-17）：Room Mute 全房静音切换（对齐蓝本 §1.2 采用 adjustPlaybackSignalVolume
        // 播放端总音量策略，不动订阅层）；文案随状态在 muteOn/muteOff 间切换
        Button(store.isRoomMuted ? L10n.PartyRoom.toolMenuRoomMuteOff : L10n.PartyRoom.toolMenuRoomMuteOn) {
            store.toggleRoomMute()
        }
        Button(L10n.Party.cancel, role: .cancel) {}
    }
}

// MARK: - PartyRoomBackgroundView

/// 派对房背景渲染器（v17 对齐 H5 `room-bg.vue` 三分支）。
///
/// **URL 分流**：
/// - 结尾 `.svga` → `RemoteSVGAImageView`（loops=0 无限循环，scaleAspectFill）
/// - 结尾 `.mp4` → `LoopingVideoView`（AVQueuePlayer + AVPlayerLooper，resizeAspectFill，muted）
/// - 其他 → `CachedAsyncImage`（静态图，等比填充 + clipped）
///
/// **动态资源 placeholder 层**：动图/视频加载期间显示 `placeholderURL`（后端 imgUrl 缩略图恒静态），
/// 就绪后 0.3s opacity 渐隐 —— 完全对齐 H5 `<Transition name="bg-placeholder">` 0.3s ease。
/// 视觉效果：先看到静态缩略图 → 动图/视频首帧就绪后平滑淡出让位给动态内容，避免白屏。
///
/// **URL 变更处理**：`.onChange(of: effectiveURL)` reset `dynamicReady` → placeholder 重新覆盖 →
/// 底层 `LoopingVideoView` / `RemoteSVGAImageView` 通过 updateUIView 内部 URL diff 换 asset。
///
/// **失败兜底**：动图/视频加载失败时 `dynamicReady` 保持 false → placeholder 常驻，
/// 用户视觉等同于静态图，符合 H5 fallback 精神。
private struct PartyRoomBackgroundView: View {
    let bigImgURL: String?
    let placeholderURL: String?
    let size: CGSize

    /// H5 `DEFAULT_BG`（`room-bg.vue:17`）。bigImgUrl / placeholderURL 都空时最终兜底。
    private static let defaultBG = "https://img.hnhily.link/mstatic/party/bg_party.png"

    @State private var dynamicReady = false

    private var effectiveURL: String {
        if let s = bigImgURL, !s.isEmpty { return s }
        if let s = placeholderURL, !s.isEmpty { return s }
        return Self.defaultBG
    }

    private var effectivePlaceholder: String {
        if let s = placeholderURL, !s.isEmpty { return s }
        return Self.defaultBG
    }

    var body: some View {
        let url = effectiveURL
        let kind = MediaAssetKind(urlString: url)
        return ZStack {
            mainContent(kind: kind, url: url)

            // 动态资源加载中的静态覆盖（就绪后 0.3s opacity 淡出）
            if kind != .image, !dynamicReady {
                staticImageView(urlStr: effectivePlaceholder)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeOut(duration: 0.3), value: dynamicReady)
        .onAppear {
            AppLogger.party.info("[PartyRoom] bg url=\(url, privacy: .public) kind=\(String(describing: kind), privacy: .public)")
        }
        .onChange(of: url) { _ in
            dynamicReady = false
        }
    }

    @ViewBuilder
    private func mainContent(kind: MediaAssetKind, url: String) -> some View {
        switch kind {
        case .image:
            staticImageView(urlStr: url)
        case .svga:
            RemoteSVGAImageView(
                url: URL(string: url),
                loops: 0,
                contentMode: .scaleAspectFill,
                onFirstPlay: { dynamicReady = true }
            )
            .frame(width: size.width, height: size.height)
            .clipped()
        case .mp4:
            LoopingVideoView(url: URL(string: url)) {
                dynamicReady = true
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    private func staticImageView(urlStr: String) -> some View {
        CachedAsyncImage(url: URL(string: urlStr), contentMode: .fill, persistent: true) {
            Image("partyRoomBg")
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

// MARK: - PartyShareSheet (F 期便利功能, 2026-07-17)

/// UIActivityViewController wrapper —— SwiftUI ShareLink 是 View 无法从 button action 触发；
/// 用 UIViewControllerRepresentable 通过 `.sheet` 承载 UIActivityViewController 实现程序化触发。
/// 分享内容通常是 `[String]`（文案含深链），iOS 系统面板会自动识别 URL。
private struct PartyShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
