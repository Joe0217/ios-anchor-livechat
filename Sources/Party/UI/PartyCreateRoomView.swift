import SwiftUI

/// 派对房创建页（spec §1.4.7）。MVP 仅房名 + 模板二字段；
/// 封面/语言/欢迎语/背景图 F 期补。
///
/// 提交流程：
/// 1. `PartyAPI.createRoom` → `PartyRoomInfo`
/// 2. 返回的 `roomId` 自动 push 进 PartyRoomView（PartyRoomView 内 `ensureEntered()` 触发 enterRoom）
struct PartyCreateRoomView: View {
    @State private var roomName: String = ""
    @State private var templates: [PartyRoomTemplate] = []
    @State private var selectedTemplate: PartyRoomTemplate?
    @State private var loadingTemplates = false
    @State private var loadError: String = ""
    @State private var isSubmitting = false
    @State private var submitError: String = ""
    @State private var createdRoomId: String = ""
    @State private var pushRoom: Bool = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("房间名称") {
                TextField("最多 20 个字", text: $roomName)
                    .onChange(of: roomName) { new in
                        if new.count > 20 { roomName = String(new.prefix(20)) }
                    }
            }
            Section("选择模板") {
                if loadingTemplates {
                    HStack { ProgressView(); Text("加载模板…") }
                } else if !loadError.isEmpty {
                    Text(loadError).foregroundColor(.red).font(.caption)
                    Button("重试") { Task { await loadTemplates() } }
                } else if templates.isEmpty {
                    Text("dev 暂无可用模板").foregroundColor(.secondary).font(.caption)
                } else {
                    ForEach(templates) { temp in
                        Button {
                            selectedTemplate = temp
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(temp.name ?? "模板 \(temp.id)")
                                        .foregroundColor(.primary)
                                    Text("总麦位 \(temp.seatCount ?? 0) · 视频 \(temp.videoSeatCount ?? 0) · 语聊 \(temp.voiceSeatCount ?? 0)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if selectedTemplate?.id == temp.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }
            }
            if !submitError.isEmpty {
                Section { Text(submitError).foregroundColor(.red).font(.caption) }
            }
            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        Spacer()
                        if isSubmitting { ProgressView().padding(.trailing, 6) }
                        Text("创建房间").bold()
                        Spacer()
                    }
                }
                .disabled(!canSubmit || isSubmitting)
            }
        }
        .navigationTitle("创建派对房")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $pushRoom) {
            PartyRoomView(roomId: createdRoomId)
        }
        .task { await loadTemplates() }
    }

    private var canSubmit: Bool {
        !roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedTemplate != nil
    }

    @MainActor
    private func loadTemplates() async {
        loadingTemplates = true
        loadError = ""
        defer { loadingTemplates = false }
        do {
            templates = try await PartyAPI.roomTempList()
            if selectedTemplate == nil { selectedTemplate = templates.first }
        } catch let api as PartyAPIError {
            loadError = api.errorDescription ?? "模板加载失败"
        } catch {
            loadError = "模板加载失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func submit() async {
        guard let temp = selectedTemplate else { return }
        let name = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isSubmitting = true
        submitError = ""
        defer { isSubmitting = false }
        do {
            let info = try await PartyAPI.createRoom(
                roomName: name,
                roomTempId: temp.id
            )
            guard let id = info.id, !id.isEmpty else {
                submitError = "服务端未返 roomId"
                return
            }
            createdRoomId = id
            pushRoom = true
        } catch let api as PartyAPIError {
            submitError = api.errorDescription ?? "创建失败"
        } catch {
            submitError = "创建失败：\(error.localizedDescription)"
        }
    }
}
