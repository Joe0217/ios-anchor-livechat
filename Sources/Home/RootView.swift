import SwiftUI

/// 根视图：按登录态在登录页与首页之间切换。
struct RootView: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        if session.isLoggedIn {
            HomeView()
        } else {
            LoginView()
        }
    }
}
