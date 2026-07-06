import SwiftUI

/// 根视图：按登录态在登录页与首页之间切换；登录后启动 CallStore RTM 信令。
/// 任何时刻 CallStore.state 非 idle 都会全屏覆盖 CallView（来电浮层 + 通话主界面）。
struct RootView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var callStore = CallStore.shared
    @StateObject private var autoOffline = AutoOfflineMonitor.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if session.isLoggedIn {
                MainTabView()
            } else {
                LoginView()
            }

            // 通话全局浮层：CallStore 状态非 idle 即覆盖
            if callStore.state != .idle {
                CallView(store: callStore)
                    .transition(.opacity)
                    .zIndex(100)
            }

            // 长时间无操作自动离线弹窗（对齐 H5 App.vue useDynamicInactivityTimer）
            if autoOffline.showDialog {
                AutoOfflineDialog(
                    onGoOnline: { autoOffline.handleGoOnline() },
                    onDismiss: { autoOffline.handleDialogDismiss() }
                )
                .transition(.opacity)
                .zIndex(200)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: callStore.state)
        .animation(.easeInOut(duration: 0.15), value: autoOffline.showDialog)
        // 全局交互兜底：任何 tap / drag 都视为活动信号
        // simultaneousGesture 不拦截业务手势，只做观察
        .simultaneousGesture(TapGesture().onEnded { autoOffline.pokeActivity() })
        .simultaneousGesture(DragGesture(minimumDistance: 0).onEnded { _ in autoOffline.pokeActivity() })
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active { autoOffline.pokeActivity() }
        }
        .task(id: session.isLoggedIn) {
            await syncSessionDependent()
        }
        #if DEBUG
        .debugLocaleSwitcher()
        #endif
    }

    /// 登录态相关的全局连接同步：
    /// - WSHeartbeat：5s 心跳上报 onlineStatus —— 用户端"主播在线"列表字段的实际驱动源
    /// - NIM 长连：云信 presence + IM 通道（接收 attachType 消息）
    /// - CallStore RTM：1v1 通话信令通道
    private func syncSessionDependent() async {
        if session.isLoggedIn, let user = session.user {
            if let uuid = user.loginUuid, !uuid.isEmpty {
                WSHeartbeat.shared.start(loginUuid: uuid)
            }
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

            // 长时间无操作自动离线：拉配置后启动（服务端 max_no_use_app_reminder_time > 0 才启用）
            let minutes = await AppConfigService.fetchAutoOfflineReminderMinutes()
            AutoOfflineMonitor.shared.start(reminderMinutes: minutes)
        } else {
            WSHeartbeat.shared.stop()
            NIMOnlineKeeper.shared.stop()
            await callStore.stop()
            AutoOfflineMonitor.shared.stop()
        }
    }
}
