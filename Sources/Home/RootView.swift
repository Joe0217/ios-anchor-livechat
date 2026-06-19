import SwiftUI

/// 根视图：按登录态在登录页与首页之间切换；登录后启动 CallStore RTM 信令。
/// 任何时刻 CallStore.state 非 idle 都会全屏覆盖 CallView（来电浮层 + 通话主界面）。
struct RootView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var callStore = CallStore.shared

    var body: some View {
        ZStack {
            if session.isLoggedIn {
                HomeView()
            } else {
                LoginView()
            }

            // 通话全局浮层：CallStore 状态非 idle 即覆盖
            if callStore.state != .idle {
                CallView(store: callStore)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: callStore.state)
        .task(id: session.isLoggedIn) {
            await syncSessionDependent()
        }
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
        } else {
            WSHeartbeat.shared.stop()
            NIMOnlineKeeper.shared.stop()
            callStore.stop()
        }
    }
}
