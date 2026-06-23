import SwiftUI

/// 临时 POC 调试台：通话/直播/账号入口集合。
///
/// 阶段一为方便真机自测保留。由 Work tab → Tools → Invite 工具入口 push 进入，
/// 复用 WorkView 的 NavigationStack，主层级 tabbar 不受影响。
/// 后续上线前整体删除。
struct POCDebugView: View {
    @EnvironmentObject private var session: SessionStore
    @ObservedObject private var callStore = CallStore.shared

    @State private var dialUserId: String = ""
    @State private var showDialAlert = false

    var body: some View {
        // push 进入：复用外层 WorkView 的 NavigationStack，不再自己嵌套一层。
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
        .navigationBarTitleDisplayMode(.inline)
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
            HStack {
                Image(systemName: rtmIcon)
                    .foregroundStyle(rtmColor)
                Text(rtmText)
                Spacer()
                Text(callStore.state.rawValue)
                    .font(.caption).foregroundStyle(.secondary)
            }

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
        callStore.rtmConnectionState == .connected &&
        callStore.state == .idle &&
        !dialUserId.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - RTM 状态 UI 派生

    private var rtmIcon: String {
        switch callStore.rtmConnectionState {
        case .connected:    return "antenna.radiowaves.left.and.right"
        case .reconnecting, .connecting: return "antenna.radiowaves.left.and.right"
        case .disconnected, .idle: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    private var rtmColor: Color {
        switch callStore.rtmConnectionState {
        case .connected:    return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected: return .red
        case .idle:         return .secondary
        }
    }

    private var rtmText: String {
        if !callStore.isSignalingReady { return "RTM 信令未就绪" }
        switch callStore.rtmConnectionState {
        case .connected:    return "RTM 信令已就绪"
        case .connecting:   return "RTM 连接中…"
        case .reconnecting: return "RTM 重连中…"
        case .disconnected: return "RTM 已断连，等待恢复"
        case .idle:         return "RTM 信令未就绪"
        }
    }

    private func dial() async {
        let target = dialUserId.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        await callStore.callOut(remoteUserId: target)
    }
}
