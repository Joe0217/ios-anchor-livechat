import SwiftUI

/// 首页：调试功能入口。后续新增的原生功能 demo 都从这里进入。
struct HomeView: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        CallPOCView().navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("美颜 + 1v1 通话 POC", systemImage: "video.fill")
                    }
                    NavigationLink {
                        LivePrepareView()
                    } label: {
                        Label("直播开播 Demo", systemImage: "dot.radiowaves.left.and.right")
                    }
                } header: {
                    Text("调试功能")
                } footer: {
                    Text("相机 / 美颜 / 声网均需真机测试")
                }

                Section("账号") {
                    if let name = session.user?.nickname, !name.isEmpty {
                        Label(name, systemImage: "person.crop.circle")
                    }
                    if let uid = session.user?.userId {
                        LabeledContent("userId", value: "\(uid)")
                    }
                    Button(role: .destructive) {
                        session.logout()
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Anchor POC 调试台")
        }
    }
}
