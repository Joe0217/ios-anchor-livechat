import SwiftUI

/// 首页：调试功能入口。后续新增的原生功能 demo 都从这里进入。
struct HomeView: View {
    @EnvironmentObject private var session: SessionStore
    @ObservedObject private var callStore = CallStore.shared
    @State private var dialUserId: String = ""
    @State private var showDialAlert = false

    var body: some View {
        NavigationStack {
            List {
                Section("调试功能") {
                    NavigationLink {
                        CallPOCView().navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("美颜 + 单端入频道 POC", systemImage: "video.fill")
                    }
                    NavigationLink {
                        LivePrepareView()
                    } label: {
                        Label("直播开播 Demo", systemImage: "dot.radiowaves.left.and.right")
                    }
                }

                callSection

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
        .alert("通话异常", isPresented: $showDialAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(callStore.lastError)
        }
        .onChange(of: callStore.lastError) { newValue in
            showDialAlert = !newValue.isEmpty && callStore.state == .idle
        }
    }

    private var callSection: some View {
        Section {
            // 信令状态
            HStack {
                Image(systemName: callStore.isSignalingReady ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(callStore.isSignalingReady ? .green : .orange)
                Text(callStore.isSignalingReady ? "RTM 信令已就绪" : "RTM 信令未就绪")
                Spacer()
                Text(callStore.state.rawValue)
                    .font(.caption).foregroundStyle(.secondary)
            }

            // 拨号入口
            HStack {
                TextField("对方 userId", text: $dialUserId)
                    .keyboardType(.numberPad)
                    .textContentType(.username)
                Button {
                    Task { await dial() }
                } label: {
                    Label("拨打", systemImage: "phone.fill.arrow.up.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canDial)
            }
        } header: {
            Text("1v1 通话")
        } footer: {
            Text("两台真机各登录一个主播账号，分别在对端输入彼此 userId 即可对拨。")
        }
    }

    private var canDial: Bool {
        callStore.isSignalingReady &&
        callStore.state == .idle &&
        !dialUserId.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func dial() async {
        let target = dialUserId.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        await callStore.callOut(remoteUserId: target)
    }
}
