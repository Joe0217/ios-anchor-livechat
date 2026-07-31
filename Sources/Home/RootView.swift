import SwiftUI

/// 根视图：按登录态和角色能力在登录、受限、主播主界面之间切换。
/// `107` 是 Party-only 角色：可进入主界面，但不能启动完整主播实时能力。
struct RootView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var callStore = CallStore.shared
    @StateObject private var robotCallStore = RobotCallStore.shared
    @StateObject private var autoOffline = AutoOfflineMonitor.shared
    @StateObject private var mediaPermissionAlert = MediaPermissionAlertCenter.shared
    @StateObject private var startupStationMail = StartupStationMailStore()
    @StateObject private var inviteMessage = InviteMessageCenter.shared
    @ObservedObject private var matchStore = MatchStore.shared
    @ObservedObject private var permission = SelfPermissionBridge.shared
    @Environment(\.scenePhase) private var scenePhase
    /// v23（2026-07-13）code-review 修复：warmup Task 需要 cancel 入口
    /// 场景：快速 login→logout→login（token 失效重刷）→ 旧 Task 迟到对新 router 冗余 warmup + 与新 Task 双打
    @State private var warmupTask: Task<Void, Never>?

    var body: some View {
        // 2026-07-17 tap-fix diagnostic:确认用户实际进入的分支(RestrictedTabView vs MainTabView vs LoginView)
        let _ = AppLogger.auth.info("[RootView] body eval: isLoggedIn=\(session.isLoggedIn, privacy: .public) isRestricted=\(self.isRestricted, privacy: .public) userType=\(session.user?.userType ?? -999, privacy: .public)")
        return ZStack {
            if !session.isLoggedIn {
                LoginView()
            } else if isAgency {
                AgencyLoginUnsupportedView { session.logout() }
            } else if isRestricted {
                // 缺失角色字段时 fail-closed，防止不完整登录响应放行未审核账号。
                RestrictedTabView()
            } else {
                MainTabView(initialSelection: session.user?.userType == 107 ? .party : .home)
            }

            // 直播私 call 由 LiveRoomView 持有的 CallView 展示，并注入直播相机。
            // 根层若再创建一个未注入相机的 CallView，会竞争相机、抢占 Agora remoteView，导致双方画面黑屏。
            // 角色被服务端降级时，即使 RTM 尚在异步停机，也不能覆盖受限页。
            if hasFullHostRealtimeCapability,
               callStore.state != .idle,
               callStore.current.frontGameType != .live {
                CallView(store: callStore)
                    .transition(.opacity)
                    .zIndex(100)
            }

            if hasFullHostRealtimeCapability, robotCallStore.state != .idle || robotCallStore.reward != nil {
                RobotCallOverlay(store: robotCallStore)
                    .transition(.opacity)
                    .zIndex(150)
            }

            // 长时间无操作自动离线弹窗（对齐 H5 App.vue useDynamicInactivityTimer）
            if hasFullHostRealtimeCapability, autoOffline.showDialog {
                AutoOfflineDialog(
                    onGoOnline: { autoOffline.handleGoOnline() },
                    onDismiss: { autoOffline.handleDialogDismiss() }
                )
                .transition(.opacity)
                .zIndex(200)
            }

            // 启动站内信（对齐 H5 GLoadList）：独立于消息页入口，登录后全局展示最新未读公告。
            if permission.canSystemAnnouncements, let mail = startupStationMail.mail {
                StartupStationMailPopup(
                    mail: mail,
                    isRead: startupStationMail.isRead,
                    onMarkRead: { startupStationMail.markRead() },
                    onDismiss: { startupStationMail.dismiss() }
                )
                .transition(.opacity)
                .zIndex(350)
            }

            // 裂变邀请 103/104：通话/机器人通话不展示，避免覆盖核心实时链路。
            if hasFullHostRealtimeCapability,
               scenePhase == .active,
               inviteMessage.isAtRootPage,
               callStore.state == .idle,
               robotCallStore.state == .idle,
               (matchStore.state == .ended || matchStore.state == .blocked),
               let prompt = inviteMessage.current {
                InviteMessageCard(center: inviteMessage, prompt: prompt)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(250)
            }

            // 全局顶部错误通知（envelope 解析失败等）—— 最高层级，
            // 空态时内部只保留 Spacer 不拦截 hit test，出现时仅胶囊区域可交互
            GlobalErrorBanner()
                .zIndex(300)

            // 美颜页会先 dismiss 再通过 MediaPermissionAlertCenter 请求提示。
            // 使用自定义模态层，避免与审核/通话的系统 alert 互相抢占而丢失提示。
            if let requirement = callStore.mediaPermissionAlertRequirement {
                MediaPermissionDialog(
                    requirement: requirement,
                    onCancel: { callStore.mediaPermissionAlertRequirement = nil },
                    onConfirm: {
                        Task { await callStore.retryMediaPermissionFromAlert(requirement) }
                    }
                )
                .transition(.opacity)
                .zIndex(410)
            } else if let requirement = mediaPermissionAlert.requirement {
                MediaPermissionDialog(
                    requirement: requirement,
                    onCancel: { mediaPermissionAlert.dismiss() },
                    onConfirm: {
                        Task { await mediaPermissionAlert.retry(requirement) }
                    }
                )
                .transition(.opacity)
                .zIndex(400)
            }
        }
        // v16：全局 toast overlay（AppToastCenter.shared） —— 关注/取关等 service 层触发的
        // 跨场景成功反馈统一走此挂点；对齐 H5 全局 `showNotify(...)` 模式
        .appToastOverlay()
        // P1-6（2026-07-14）主播审核结果弹窗（sysMsg attachType=58）。
        // 挂 RootView 而非 MainTabView：logout 后 MainTabView dismantle 会闪一下，
        // RootView 一直存活（登录前后都在），alert 生命周期与 SessionStore 一致。
        .alert(item: $session.auditAlert) { ctx in
            Alert(
                title: Text(L10n.commonKindReminder),
                message: Text(ctx.content),
                dismissButton: .default(Text(L10n.commonConfirm)) {
                    session.confirmAuditAlert(ctx)
                }
            )
        }
        .animation(.easeInOut(duration: 0.2), value: callStore.state)
        .animation(.easeInOut(duration: 0.2), value: robotCallStore.state)
        .animation(.easeInOut(duration: 0.15), value: autoOffline.showDialog)
        // 全局交互兜底：任何 tap / drag 都视为活动信号
        // simultaneousGesture 不拦截业务手势，只做观察。
        // ⚠️ **minimumDistance 必须 >0**（2026-07-08 真根因）：minDist=0 让 DragGesture 在 touch-down
        // 立即 recognize，SwiftUI gesture arbitration 会让下层业务 Slider / DragGesture / UIKit UISlider
        // tracking 全部被这个 root-level "greedy" gesture 抢先——app 里**所有 pan 手势全废**（tap 幸存
        // 因 TapGesture 是独立类型）。minDist=10 让 Slider 内部 gesture（touch-down 立即 recognize）
        // 先声明优先权；用户拖动 >10pt 才算 activity（业务语义正确，微小抖动不算）。
        .simultaneousGesture(TapGesture().onEnded { autoOffline.pokeActivity() })
        .simultaneousGesture(DragGesture(minimumDistance: 10).onEnded { _ in autoOffline.pokeActivity() })
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                autoOffline.pokeActivity()
                // sapi token 前后台切回时懒续（对齐 H5 App.vue:247-249 `getBagShopToken()`）
                // ensureValid 内部走 needsRefresh 判定：距过期 <24h 才真跑 exchange；否则 O(1) 命中缓存
                if session.isLoggedIn {
                    Task { try? await SapiTokenStore.shared.ensureValid() }
                }
            }
        }
        .task(id: sessionCapabilityKey) {
            await syncSessionDependent()
        }
        .task(id: "\(sessionCapabilityKey)-\(permission.canSystemAnnouncements)") {
            guard session.isLoggedIn,
                  permission.canSystemAnnouncements,
                  let userId = session.user?.userId else {
                startupStationMail.clear()
                return
            }
            await startupStationMail.loadIfNeeded(for: userId)
        }
        // App 级语言环境注入（Settings → Language 切换后立即生效）
        .appLocaleEnvironment()
    }

    /// 完整主播和 Party-only 角色可进入主界面。
    private var canEnterMainApp: Bool {
        let userType = session.user?.userType
        return userType == 2 || userType == 107
    }

    /// 仅完整主播允许启动 RTM、WS、匹配、直播、机器人通话等完整实时能力。
    private var hasFullHostRealtimeCapability: Bool {
        session.user?.userType == 2
    }

    private var isAgency: Bool {
        session.user?.userType == 9
    }

    /// 已登录却缺少角色字段时保持受限，避免不完整响应绕过审核页。
    private var isRestricted: Bool {
        !canEnterMainApp
    }

    /// 角色能力变化时也要重新同步主播能力。
    private var sessionCapabilityKey: String {
        let user = session.user
        return "\(session.isLoggedIn)-\(user?.userId ?? -1)-\(user?.userType ?? -1)"
    }

    /// 登录态连接同步：NIM 保留给受限页客服聊天和 Party-only 会话；
    /// 只有完整主播角色才启动主播专属实时能力。
    private func syncSessionDependent() async {
        if session.isLoggedIn, let user = session.user {
            // 受限页仍需 NIM 联系管理员、接收 attachType=58；但其他主播实时能力全部关闭。
            guard hasFullHostRealtimeCapability else {
                if let account = user.yxAccid, !account.isEmpty,
                   let token = user.imToken, !token.isEmpty {
                    NIMOnlineKeeper.shared.start(account: account, token: token)
                }
                Task { try? await SapiTokenStore.shared.ensureValid() }
                // Party-only 角色保留 Party 的 RTC/NIM 会话和 chat router；其他受限角色沿用完整清理。
                await stopHostCapabilities(preservingPartySession: canEnterMainApp)
                // Party-only 角色不在登录时常驻 WS；但正在 Party 房时必须立刻恢复带 roomId 的心跳，
                // 否则后端的 30s Party TTL 会把本端强制下麦。
                if canEnterMainApp {
                    // PartyRoomView 在小窗态已卸载，不能依赖页面级权限观察来停止热门/周任务。
                    // 保留普通 Party 会话，但立即撤销活动任务的后台网络与人脸校验链路。
                    PartyStore.shared.suspendPartyActivitiesForRestrictedRole()
                    // PartyRoomView 在小窗态已经卸载，不能依赖其 onChange 撤销已有 RTC 视频订阅。
                    // 角色从完整主播动态降为 Party-only 时，在根级同步中收敛为纯语音 Party 会话。
                    PartyStore.shared.refreshPartyVideoCapability()
                    PartyStore.shared.resumePartyOnlyHeartbeatIfNeeded()
                }
                return
            }
            // GiftEffect 引擎冷启：Window + install 生产 router + 5s 后 warmup SVGA parser
            if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first {
                GiftEffectOverlayWindow.shared.show(on: scene)
            }
            GiftEffectCenter.shared.installPlayerRouter(GiftPlayerRouter())
            // v23（2026-07-11）EnterEffect 独立并行 Player Router 实例
            // （SVGAAnimationPlayer / YYEVAAnimationPlayer 都是实例字段，第二个 GiftPlayerRouter() 天然独立
            //  → 与 GiftEffect 可同时播放全屏 SVGA/MP4，对齐用户明示 "队列分开，允许同时播放"）
            EnterEffectCenter.shared.installPlayerRouter(GiftPlayerRouter())
            // v23（2026-07-13）store Task handle 供 logout 时 cancel（避免旧 Task 对新 router 冗余 warmup）
            warmupTask?.cancel()
            warmupTask = Task { @MainActor in
                // iOS 16+ Duration API：类型安全避免 nanoseconds 位数手误漏 0 → runtime bug
                // （对齐 code-review-discipline §9.5 正例）
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                GiftEffectCenter.shared.warmupSVGA()
                // 300ms 间隔避免两组 SDK 实例同时首次分配 GPU 资源 spike 内存
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                EnterEffectCenter.shared.warmupSVGA()
            }

            if let uuid = user.loginUuid, !uuid.isEmpty {
                WSHeartbeat.shared.start(loginUuid: uuid)
            }
            // sapi token 启动懒续（对齐 H5 App.vue:162-164 冷启动检查）：
            // ensureValid 内部走 needsRefresh 判定：距过期 <24h / 未取过 才真跑 exchange；否则 O(1) 命中缓存。
            // 与 applyLogin 尾部的 forceRefresh 并发：SapiTokenStore.runExchange 有 inflightExchange 合并，只会跑一次。
            Task { try? await SapiTokenStore.shared.ensureValid() }
            if let account = user.yxAccid, !account.isEmpty,
               let token = user.imToken, !token.isEmpty {
                NIMOnlineKeeper.shared.start(account: account, token: token)
            }
            if let uid = user.userId {
                await callStore.start(myUserId: uid)
            }
            // L 里程碑 #3a：CallStore 自动接听判定 —— 匹配态收到 videoCall 直接 accept 不弹浮层
            callStore.isMatchActive = { MatchStore.shared.state == .matching }
            // L 里程碑 U3/U4：CallStore + NIM observer bridge 挂载（登录后一次）
            MatchStore.shared.attachCallStoreBridge(CallStoreMatchBridge.shared)
            MatchStore.shared.attachNIMConnectionBridge(NIMConnectionMatchBridge.disconnectedPublisher)
            // Gap-2：openMatch 前置 IM 在线 gate（对齐 H5 c-goMatch.vue:394-395）
            MatchStore.shared.nimOnlineProvider = { NIMService.shared.connectionState == .connected }
            // 用户诉求 2026-07-08：openMatch 时若 offline 自动上线（对齐 H5 !IMOnline 时 setIMOnline(true) 语义）
            // 返 true 表示"刚从 offline 切到 online"——openMatch 据此 skip IM gate（用户明确意图 → 强开匹配）
            MatchStore.shared.ensureUserOnlineHook = {
                if !OnlineStatusStore.shared.userSetOnline {
                    OnlineStatusStore.shared.setUserSetOnline(true)
                    return true
                }
                return false
            }

            // 长时间无操作自动离线：拉配置后启动（服务端 max_no_use_app_reminder_time > 0 才启用）
            let minutes = await AppConfigService.fetchAutoOfflineReminderMinutes()
            AutoOfflineMonitor.shared.start(reminderMinutes: minutes)
        } else {
            NIMOnlineKeeper.shared.stop()
            await stopHostCapabilities()
        }
    }

    /// 角色降级和登出共用的主播能力清理。NIM 由调用方控制，受限页仍需要它。
    ///
    /// `preservingPartySession` 仅用于 Party-only 角色：它必须关闭完整主播能力，同时保留 Party 房和
    /// 对应 IM router。Party、直播和通话共用声网进程级单例，因此该分支也不能销毁该引擎。
    private func stopHostCapabilities(preservingPartySession: Bool = false) async {
        WSHeartbeat.shared.stop()
        // 先结束所有活跃媒体。CallStore.stop() 会销毁共享 Agora 引擎，必须最后执行，
        // 否则直播/机器人播报/派对房来不及正常 leave。
        MatchStore.shared.stopForSessionEnd()
        await LiveSessionRegistry.shared.stopForSessionEnd()
        await robotCallStore.resetForSessionEnd()
        if !preservingPartySession {
            await PartyStore.shared.forceLeaveRoom(.userRequest)
            PartyStore.shared.detachChatRouter()
        }

        // Party 私 call 被角色降级中断时，PartyStore 仍处于 .joined 但 RTC 已为私 call 离开。
        // 先让 CallStore 释放通话，再重新加入原 Party 房；不能依赖其异步 observer，因为 stop()
        // 会立即清空 current。
        let shouldResumePartyAfterStoppingCall = preservingPartySession
            && callStore.current.frontGameType == .party
            && PartyStore.shared.roomState == .joined
        await callStore.stop(destroySharedAgoraEngine: !preservingPartySession)
        if shouldResumePartyAfterStoppingCall {
            await PartyStore.shared.resumeParty()
        }
        AutoOfflineMonitor.shared.stop()
        warmupTask?.cancel()
        warmupTask = nil
        GiftEffectCenter.shared.reset()
        EnterEffectCenter.shared.reset()
        GiftEffectOverlayWindow.shared.hide()
    }
}

// MARK: - 启动站内信（H5 App.vue + g-loadList.vue）

/// H5 将启动弹窗的已读 id 存在 localStorage.loadList，与消息页 Station 未读态分开。
/// iOS 用单独的 UserDefaults key 保留相同语义，避免点击消息列表后错误吞掉启动弹窗。
@MainActor
private final class StartupStationMailStore: ObservableObject {
    @Published private(set) var mail: StationMail?
    @Published private(set) var isRead = false

    private static let readMailIdKey = "hily.station.launchPopup.readId"
    private let service: StationListProviderProtocol
    private var requestedUserId: Int?

    init(service: StationListProviderProtocol = StationListService.shared) {
        self.service = service
    }

    func loadIfNeeded(for userId: Int) async {
        guard requestedUserId != userId else { return }
        requestedUserId = userId

        // H5 在登录主流程完成 5 秒后请求，避免和启动/鉴权请求争抢。
        do {
            try await Task.sleep(for: .seconds(5))
        } catch {
            return
        }
        guard !Task.isCancelled,
              requestedUserId == userId,
              SessionStore.shared.isLoggedIn,
              SessionStore.shared.user?.userId == userId,
              SelfPermissionBridge.shared.canSystemAnnouncementsSnapshot,
              let latest = await service.fetchLatest(),
              latest.id != UserDefaults.standard.string(forKey: Self.readMailIdKey) else {
            return
        }
        mail = latest
        isRead = false
    }

    func markRead() {
        guard let mail else { return }
        guard !isRead else {
            AppToastCenter.shared.show(L10n.stationPopupAlreadyRead)
            return
        }
        isRead = true
        UserDefaults.standard.set(mail.id, forKey: Self.readMailIdKey)
    }

    func dismiss() {
        // H5 点击遮罩只关闭，不写 loadList，下一次启动仍会再次提醒。
        mail = nil
    }

    func clear() {
        requestedUserId = nil
        mail = nil
        isRead = false
    }
}

private struct StartupStationMailPopup: View {
    let mail: StationMail
    let isRead: Bool
    let onMarkRead: () -> Void
    let onDismiss: () -> Void
    @State private var galleryContext: MediaGalleryContext?
    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            GeometryReader { proxy in
                let modalWidth = min(360, max(0, proxy.size.width - 40))
                let maxModalHeight = max(200, proxy.size.height * 0.7)
                let modalHeight = min(max(naturalHeight, 200), maxModalHeight)

                VStack(spacing: 0) {
                    header
                    Divider().overlay(Color.white.opacity(0.22))
                    ScrollView {
                        mailBody
                    }
                    Divider().overlay(Color.white.opacity(0.22))
                    footer
                }
                .frame(width: modalWidth)
                .frame(height: modalHeight, alignment: .top)
                .background(Color(hex: 0x2B213E), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
                .background {
                    naturalPopup(width: modalWidth)
                        .hidden()
                        .allowsHitTesting(false)
                }
                .onPreferenceChange(StartupStationMailNaturalHeightKey.self) { naturalHeight = $0 }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        // 统一使用 MediaGalleryView，避免单图预览绕开公共 20MB LRU 和手势/a11y 语义。
        .fullScreenCover(item: $galleryContext) { ctx in
            MediaGalleryView(urls: ctx.urls, startIndex: ctx.startIndex)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onMarkRead) {
                HStack(spacing: 7) {
                    Image("messageInboxStation")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                    Text(mail.mailTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Button(action: onMarkRead) {
                HStack(spacing: 5) {
                    Image(systemName: isRead ? "envelope.open.fill" : "envelope.badge.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text(isRead ? L10n.stationPopupRead : L10n.stationPopupUnread)
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(isRead ? .gray : .white)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    private func naturalPopup(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.22))
            mailBody
            Divider().overlay(Color.white.opacity(0.22))
            footer
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: StartupStationMailNaturalHeightKey.self,
                    value: geometry.size.height
                )
            }
        }
    }

    private var mailBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.plainText(from: mail.mailContent))
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onTapGesture(perform: onMarkRead)

            ForEach(Array(imageURLs.enumerated()), id: \.offset) { index, url in
                Button {
                    onMarkRead()
                    galleryContext = MediaGalleryContext(
                        urls: imageURLs.map(\.absoluteString),
                        startIndex: index
                    )
                } label: {
                    CachedAsyncImage(url: url, contentMode: .fit, persistent: true) {
                        ProgressView().tint(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 120, maxHeight: 260)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
    }

    private var footer: some View {
        Button(action: onMarkRead) {
            HStack {
                Spacer()
                Text("\(L10n.stationPopupExpirationDate): \(mail.expiryDate)")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private static func plainText(from html: String) -> String {
        // H5 用 v-html 渲染正文；原生文本视图不承载样式，但需要保留段落和换行语义。
        let withLineBreaks = html
            .replacingOccurrences(
                of: #"<br\s*/?>"#,
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"</(?:p|div|li|h[1-6])\s*>"#,
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
        let noTags = withLineBreaks.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return noTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func imageURLs(from html: String) -> [URL] {
        let pattern = #"<img[^>]+src=[\"']([^\"'>]+)[\"']"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        return expression.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let urlRange = Range(match.range(at: 1), in: html),
                  let url = URL(string: String(html[urlRange])),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else {
                return nil
            }
            return url
        }
    }

    private var imageURLs: [URL] {
        Self.imageURLs(from: mail.mailContent)
    }
}

private struct StartupStationMailNaturalHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// H5 `GAgencyLoginPop` 的 iOS 对应物。代理账号不能进入主播端，唯一操作是退出。
private struct AgencyLoginUnsupportedView: View {
    let onSignOut: () -> Void

    var body: some View {
        ZStack {
            Theme.Palette.profileBackground.ignoresSafeArea()
            VStack(spacing: 20) {
                Text("Proxy account login is not currently supported. Please login using the proxy app")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Button("Sign out", action: onSignOut)
                    .buttonStyle(.borderedProminent)
            }
            .padding(32)
        }
        .preferredColorScheme(.dark)
    }
}
