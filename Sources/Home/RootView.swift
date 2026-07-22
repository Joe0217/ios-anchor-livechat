import SwiftUI

/// 根视图：按登录态和审核角色在登录、受限、主播主界面之间切换。
/// 通话和主播实时能力只允许已审核主播（`userType == 2`）启动。
struct RootView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var callStore = CallStore.shared
    @StateObject private var robotCallStore = RobotCallStore.shared
    @StateObject private var autoOffline = AutoOfflineMonitor.shared
    @StateObject private var mediaPermissionAlert = MediaPermissionAlertCenter.shared
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
                MainTabView()
            }

            // 角色被服务端降级时，即使 RTM 尚在异步停机，也不能覆盖受限页。
            if isApprovedHost, callStore.state != .idle {
                CallView(store: callStore)
                    .transition(.opacity)
                    .zIndex(100)
            }

            if isApprovedHost, robotCallStore.state != .idle || robotCallStore.reward != nil {
                RobotCallOverlay(store: robotCallStore)
                    .transition(.opacity)
                    .zIndex(150)
            }

            // 长时间无操作自动离线弹窗（对齐 H5 App.vue useDynamicInactivityTimer）
            if isApprovedHost, autoOffline.showDialog {
                AutoOfflineDialog(
                    onGoOnline: { autoOffline.handleGoOnline() },
                    onDismiss: { autoOffline.handleDialogDismiss() }
                )
                .transition(.opacity)
                .zIndex(200)
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
        // App 级语言环境注入（Settings → Language 切换后立即生效）
        .appLocaleEnvironment()
    }

    /// H5 `isHost` / `isAgency` 对齐：主播可进入主界面，代理被阻止，其他和未知角色受限。
    private var isApprovedHost: Bool {
        session.user?.userType == 2
    }

    private var isAgency: Bool {
        session.user?.userType == 9
    }

    /// 已登录却缺少角色字段时保持受限，避免不完整响应绕过审核页。
    private var isRestricted: Bool {
        !isApprovedHost
    }

    /// 审核角色变化时也要重新同步主播能力。
    private var sessionCapabilityKey: String {
        let user = session.user
        return "\(session.isLoggedIn)-\(user?.userId ?? -1)-\(user?.userType ?? -1)"
    }

    /// 登录态连接同步：NIM 保留给受限页客服聊天；主播专属实时能力按审核角色门控。
    private func syncSessionDependent() async {
        if session.isLoggedIn, let user = session.user {
            // 受限页仍需 NIM 联系管理员、接收 attachType=58；但其他主播实时能力全部关闭。
            guard isApprovedHost else {
                if let account = user.yxAccid, !account.isEmpty,
                   let token = user.imToken, !token.isEmpty {
                    NIMOnlineKeeper.shared.start(account: account, token: token)
                }
                Task { try? await SapiTokenStore.shared.ensureValid() }
                await stopHostCapabilities()
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
    private func stopHostCapabilities() async {
        WSHeartbeat.shared.stop()
        await callStore.stop()
        robotCallStore.resetForSessionEnd()
        AutoOfflineMonitor.shared.stop()
        warmupTask?.cancel()
        warmupTask = nil
        GiftEffectCenter.shared.reset()
        EnterEffectCenter.shared.reset()
        GiftEffectOverlayWindow.shared.hide()
        await PartyStore.shared.forceLeaveRoom(.userRequest)
        PartyStore.shared.detachChatRouter()
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
