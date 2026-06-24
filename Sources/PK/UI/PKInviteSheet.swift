import SwiftUI

/// G 里程碑 spec §6 / M3-3：发起邀请 sheet。
///
/// 输入对手 UID + pkDuration 4 档选择；提交后 dismiss 并进入 `.inviting`。
struct PKInviteSheet: View {
    @ObservedObject var store: PKStore
    @Binding var isPresented: Bool

    @State private var opponentId: String = ""
    @State private var duration: Int = 300
    private let durations: [(value: Int, label: String)] = [
        (180, L10n.PK.inviteDuration3),
        (300, L10n.PK.inviteDuration5),
        (600, L10n.PK.inviteDuration10),
        (900, L10n.PK.inviteDuration15),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.PK.invitePlaceholder, text: $opponentId)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section(L10n.PK.inviteDurationLabel) {
                    Picker(L10n.PK.inviteDurationLabel, selection: $duration) {
                        ForEach(durations, id: \.value) { item in
                            Text(item.label).tag(item.value)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button {
                        guard let id = Int(opponentId.trimmingCharacters(in: .whitespaces)), id > 0 else { return }
                        Task {
                            await store.inviteByAnchorId(id, duration: duration)
                            isPresented = false
                        }
                    } label: {
                        Text(L10n.PK.inviteSend)
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .disabled(Int(opponentId.trimmingCharacters(in: .whitespaces)) ?? 0 <= 0)
                }
            }
            .navigationTitle(L10n.PK.inviteTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.PK.matchingCancel) { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
