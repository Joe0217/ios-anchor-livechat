import SwiftUI

/// One modal owns the entire flow: success dismisses every upstream email page.
struct EmailAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: EmailAccountStore
    @State private var revealed = false
    @State private var showingFeedback = false
    @State private var feedback = ""
    @State private var showingRisk = false
    @FocusState private var codeFocused: Bool
    let onRegistration: ((String, String, String, Date) -> Void)?
    let onLogin: ((String) -> Void)?

    init(mode: EmailAccountStore.Mode, email: String = "",
         onRegistration: ((String, String, String, Date) -> Void)? = nil,
         onLogin: ((String) -> Void)? = nil) {
        _store = StateObject(wrappedValue: EmailAccountStore(mode: mode, email: email))
        self.onRegistration = onRegistration
        self.onLogin = onLogin
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if showingFeedback { feedbackContent }
                    else {
                        switch store.step {
                        case .email: emailContent
                        case .code: codeContent
                        case .password: passwordContent
                        case .complete: ProgressView()
                        }
                    }
                    if let message = store.message {
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("emailFlow.message")
                    }
                    if store.busy { ProgressView().frame(maxWidth: .infinity) }
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.Palette.profileBackground.ignoresSafeArea())
            .navigationTitle(L10n.Email.text(showingFeedback ? "feedbackTitle" : store.rebind ? "manageTitle" : "signUp"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.Email.text("back")) {
                        if showingFeedback { showingFeedback = false }
                        else if store.step == .email { close() }
                        else { store.back() }
                    }.disabled(store.busy)
                }
            }
            .alert(L10n.Email.text("confirmChange"), isPresented: $store.confirmChange) {
                Button(L10n.settingsCancel, role: .cancel) {}
                Button(L10n.settingsConfirm) { Task { await store.sendCode() } }
            } message: {
                Text(String(format: L10n.Email.text("confirmChangeBody"), store.email))
            }
            .alert(L10n.Email.text("leaveTitle"), isPresented: $store.confirmExit) {
                Button(L10n.settingsCancel, role: .cancel) {}
                Button(L10n.Email.text("leave"), role: .destructive) { close() }
            } message: { Text(L10n.Email.text("leaveBody")) }
            .alert(L10n.Email.text("manageTitle"), isPresented: $store.alreadyVerified) {
                Button(L10n.settingsConfirm) { close() }
            } message: { Text(L10n.Email.text("alreadyVerified")) }
            .alert(L10n.Email.text("changeEmail"), isPresented: $showingRisk) {
                Button(L10n.settingsCancel, role: .cancel) {}
                Button(L10n.Email.text("changeEmail")) { store.useNewEmail() }
            } message: { Text(L10n.Email.text("resetNotice")) }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(store.busy || (store.rebind && store.step == .password))
        .task { await store.load() }
        .task { await store.runClock() }
        .onChange(of: store.step) { step in
            codeFocused = step == .code
            if step == .complete {
                if !store.rebind, let expiry = store.ticketExpiresAt {
                    onRegistration?(store.email, store.password, store.ticket, expiry)
                }
                close()
            }
        }
        .onChange(of: store.returnToLogin) { value in
            if value { onLogin?(store.email); close() }
        }
    }

    private func close() { store.deactivate(); dismiss() }

    private var emailContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.Email.text(store.rebind ? "resetNotice" : "registerNotice"))
                .font(.subheadline).foregroundStyle(.secondary)
            TextField(L10n.authEmail, text: $store.email)
                .keyboardType(.emailAddress).textContentType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(store.currentIsReadOnly || store.busy)
                .textFieldStyle(.roundedBorder)
                .onChange(of: store.email) { value in
                    let cleaned = String(EmailAccountRules.clean(value).prefix(100))
                    if cleaned != value { store.email = cleaned }
                }
            if !store.loaded {
                action("retry") { await store.load() }
            } else {
                action("sendCode") { await store.requestCode() }
            }
            if !store.currentIsReadOnly, EmailAccountRules.validEmail(store.email) {
                Button(L10n.Email.text("cannotReceive")) {
                    store.message = nil
                    showingFeedback = true
                }.buttonStyle(.plain).padding(.vertical, 10).disabled(store.busy)
            }
            if store.currentIsReadOnly {
                Button(L10n.Email.text("cannotReceive")) { showingRisk = true }
                    .buttonStyle(.plain).padding(.vertical, 10)
            }
        }
    }

    private var codeContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(String(format: L10n.Email.text("codeTip"), store.email))
            ZStack {
                HStack(spacing: 8) {
                    ForEach(0..<6) { index in
                        Text(index < store.code.count ? String(Array(store.code)[index]) : (codeFocused && index == store.code.count && store.cursorVisible ? "│" : " "))
                            .font(.title2.monospacedDigit())
                            .frame(maxWidth: .infinity).frame(height: 54)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(index == store.code.count && codeFocused ? Color.pink : Color.clear))
                    }
                }
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityHidden(true)
                TextField("", text: Binding(get: { store.code }, set: { store.enterCode($0) }))
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .foregroundColor(.clear).tint(.clear)
                    .focused($codeFocused).disabled(store.busy)
                    .accessibilityLabel(L10n.Email.text("codeLabel"))
                    .accessibilityIdentifier("emailFlow.code")
            }
            Button {
                Task { await store.sendCode() }
            } label: {
                Text(store.remaining > 0 ? String(format: L10n.Email.text("resendCountdown"), store.remaining) : L10n.Email.text("resend"))
                    .foregroundStyle(store.remaining > 0 ? Color(red: 0.45, green: 0.42, blue: 0.57) : Color(red: 0.99, green: 0.23, blue: 0.55))
                    .padding(.vertical, 12)
            }.disabled(store.remaining > 0 || store.busy).buttonStyle(.plain)
            Button(L10n.Email.text("cannotReceive")) {
                store.message = nil
                showingFeedback = true
            }.buttonStyle(.plain).padding(.vertical, 10).disabled(store.busy)
        }
    }

    private var passwordContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.Email.text("passwordRule")).font(.subheadline)
            HStack {
                passwordInput(L10n.authPassword, text: $store.password)
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye").frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel(L10n.Email.text("showPassword"))
            }
            passwordInput(L10n.Email.text("confirmPassword"), text: $store.confirmation)
            if store.rebind {
                Text(String(format: L10n.Email.text("ticketCountdown"), store.ticketRemaining / 60, store.ticketRemaining % 60))
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            action(store.rebind ? "submit" : "next") { await store.acceptPassword() }
                .disabled(!store.canSubmitPassword)
        }
        .disabled(store.busy)
    }

    private func passwordInput(_ title: String, text: Binding<String>) -> some View {
        Group {
            if revealed { TextField(title, text: text) }
            else { SecureField(title, text: text) }
        }
        .textContentType(.newPassword).textInputAutocapitalization(.never).autocorrectionDisabled()
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(store.mismatch ? Color.red : Color.clear))
        .onChange(of: text.wrappedValue) { value in
            if value.count > 20 { text.wrappedValue = String(value.prefix(20)) }
            store.mismatch = false
        }
    }

    private var feedbackContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.Email.text("feedbackRule"))
            TextEditor(text: $feedback).frame(minHeight: 180)
                .onChange(of: feedback) { if $0.count > 200 { feedback = String($0.prefix(200)) } }
            Text("\(feedback.count)/200").font(.footnote).frame(maxWidth: .infinity, alignment: .trailing)
            action("submit") {
                if await store.sendFeedback(feedback) { showingFeedback = false; feedback = "" }
            }.disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).count < 5)
        }
    }
    private func action(_ key: String, operation: @escaping () async -> Void) -> some View {
        Button { Task { await operation() } } label: {
            Text(L10n.Email.text(key)).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
                .background(Color(red: 0.99, green: 0.23, blue: 0.55), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(store.busy)
    }
}
