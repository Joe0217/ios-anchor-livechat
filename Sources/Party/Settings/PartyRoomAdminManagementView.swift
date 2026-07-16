import SwiftUI

/// 派对房 · 房管管理页（对齐 H5 create.vue 编辑态 partyAdminPopup）。
///
/// 房主进入设置页 → tap "Manage Admins" 行 → 本 view。
/// - 显示当前房管列表
/// - 支持撤销（swipe / trash icon）
/// - 支持添加（用户 ID 输入 sheet；F 期可扩为选人 sheet）
struct PartyRoomAdminManagementView: View {
    @StateObject var store: PartyAdminStore

    @State private var showAddSheet = false

    init(store: PartyAdminStore) {
        _store = StateObject(wrappedValue: store)
    }

    var body: some View {
        ZStack {
            content
        }
        .navigationTitle(L10n.Party.settingsManageAdmins)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Theme.Palette.partyListBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundColor(Theme.Palette.partyCreateChevron)
                }
                .accessibilityLabel(L10n.Party.settingsAdminAdd)
            }
        }
        .task { await store.loadInitial() }
        .sheet(isPresented: $showAddSheet) {
            PartyAdminAddSheet(store: store) { showAddSheet = false }
                .giftPanelSheetBackground()
                .presentationDetents([.medium])
        }
        .overlay(alignment: .top) {
            if !store.errorMessage.isEmpty {
                Text(store.errorMessage)
                    .toastStyle()
                    .transition(Toast.transition)
                    .task(id: store.errorMessage) {
                        try? await Task.sleep(nanoseconds: Toast.dismissDurationLongNanos)
                        store.clearError()
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.errorMessage.isEmpty)
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.admins.isEmpty {
            ProgressView().tint(.white)
        } else if store.admins.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "person.2")
                    .font(.system(size: 40))
                    .foregroundColor(.white.opacity(0.35))
                Text(L10n.Party.settingsAdminEmpty)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.Palette.partyGreeting)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.admins) { admin in
                        adminRow(admin)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 12)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func adminRow(_ admin: PartyRoomAdmin) -> some View {
        HStack(spacing: 12) {
            avatar(admin)
            VStack(alignment: .leading, spacing: 2) {
                Text(admin.nickname?.isEmpty == false ? admin.nickname! : admin.userId)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                Text("ID: \(admin.userId)")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Palette.partyGreeting)
            }
            Spacer()
            Button {
                Task { await store.removeAdmin(admin) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(8)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .disabled(store.isMutating)
            .accessibilityLabel(L10n.Party.settingsAdminRemove)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.Palette.partyCreateInputFill))
    }

    @ViewBuilder
    private func avatar(_ admin: PartyRoomAdmin) -> some View {
        if let url = admin.icon, !url.isEmpty, let u = URL(string: url) {
            CachedAsyncImage(url: u, persistent: true, cdn: (.avatarSmall, .fill)) {
                Circle().fill(Theme.Palette.partyCardFill)
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
        } else {
            Circle().fill(Theme.Palette.partyCardFill)
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: "person.fill").foregroundColor(.white.opacity(0.5)))
        }
    }
}

// MARK: - Add Admin sheet

/// 添加房管 sheet：MVP 用 userId 手动输入；F 期可扩为选人 sheet（从房间当前观众/麦位选）
struct PartyAdminAddSheet: View {
    @ObservedObject var store: PartyAdminStore
    var onClose: () -> Void

    @State private var userIdInput: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 16) {
                Text(L10n.Party.settingsAdminAddTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.top, 16)

                Text(L10n.Party.settingsAdminAddHint)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Palette.partyGreeting)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                HStack {
                    TextField(L10n.Party.settingsAdminUserIdPlaceholder, text: $userIdInput)
                        .focused($focused)
                        .keyboardType(.numberPad)
                        .foregroundColor(Theme.Palette.partyCreateInputText)
                        .tint(Theme.Palette.partyCreateChevron)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(Capsule().fill(Theme.Palette.partyCreateInputFill))
                .overlay(Capsule().stroke(Theme.Palette.partyCreateInputBorder, lineWidth: 0.5))
                .padding(.horizontal, 20)

                Spacer()
            }

            addButton.padding(.bottom, 20).padding(.horizontal, 20)
        }
        .onAppear { focused = true }
    }

    private var addButton: some View {
        Button {
            let trimmed = userIdInput.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            Task {
                await store.addAdmin(userId: trimmed)
                onClose()
            }
        } label: {
            HStack {
                Spacer()
                if store.isMutating { ProgressView().tint(.white).padding(.trailing, 6) }
                Text(L10n.Party.settingsAdminAdd)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.vertical, 14)
            .background(Capsule().fill(
                LinearGradient(
                    colors: [Theme.Palette.partyCreateBtnA, Theme.Palette.partyCreateBtnB],
                    startPoint: .leading, endPoint: .trailing
                )
            ))
            .opacity(userIdInput.trimmingCharacters(in: .whitespaces).isEmpty || store.isMutating ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(userIdInput.trimmingCharacters(in: .whitespaces).isEmpty || store.isMutating)
    }
}
