import SwiftUI

@MainActor
final class EmailAccountEntryStore: ObservableObject {
    @Published private(set) var info: AnchorEmailInfo?
    @Published var showRisk = false
    private let service: EmailAccountServicing
    private let defaults: UserDefaults
    private var loading = false
    private var generation: UUID?
    private var requestID = UUID()

    init(service: EmailAccountServicing = EmailAccountService(), defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    func refresh() async {
        guard SessionStore.shared.isLoggedIn else { info = nil; showRisk = false; return }
        let generation = SessionStore.shared.sessionGeneration
        if self.generation != generation {
            self.generation = generation
            info = nil
            showRisk = false
            loading = false
        }
        guard !loading else { return }
        loading = true
        let request = UUID()
        requestID = request
        defer { if requestID == request { loading = false } }
        do {
            let value = try await service.current()
            guard !Task.isCancelled, SessionStore.shared.sessionGeneration == generation else { return }
            info = value
        } catch {
            // This is secondary settings information; keep a permanent change-email entry on failure.
            guard SessionStore.shared.sessionGeneration == generation else { return }
            info = nil
        }
    }

    func checkRisk() async {
        guard let userID = SessionStore.shared.user?.userId else { return }
        let expectedGeneration = SessionStore.shared.sessionGeneration
        let countKey = "anchor_email_risk_count_\(userID)"
        let dateKey = "anchor_email_risk_at_\(userID)"
        let count = defaults.integer(forKey: countKey)
        let last = defaults.double(forKey: dateKey)
        guard count < 4, last == 0 || Date().timeIntervalSince1970 - last >= 48 * 60 * 60 else { return }
        await refresh()
        guard !Task.isCancelled, SessionStore.shared.sessionGeneration == expectedGeneration,
              SessionStore.shared.user?.userId == userID,
              let info, !info.isVerified else { return }
        // Recheck after suspension so two presentations cannot spend the same local slot.
        guard defaults.integer(forKey: countKey) == count, defaults.double(forKey: dateKey) == last else { return }
        defaults.set(count + 1, forKey: countKey)
        defaults.set(Date().timeIntervalSince1970, forKey: dateKey)
        showRisk = true
    }
}

private struct EmailRiskModifier: ViewModifier {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = EmailAccountEntryStore()
    @State private var showingVerification = false
    @State private var successMessage: String?

    func body(content: Content) -> some View {
        content
            .task(id: session.sessionGeneration) { await store.checkRisk() }
            .onChange(of: scenePhase) { phase in
                if phase == .active { Task { await store.checkRisk() } }
            }
            .alert(L10n.Email.text("verifyEmail"), isPresented: $store.showRisk) {
                Button(L10n.settingsCancel, role: .cancel) {}
                Button(L10n.Email.text("verifyEmail")) { showingVerification = true }
            } message: { Text(L10n.Email.text("riskNotice")) }
            .sheet(isPresented: $showingVerification) { EmailAccountView(mode: .verify) }
            .overlay(alignment: .top) {
                if let successMessage { Text(successMessage).toastStyle() }
            }
            .task(id: successMessage) {
                guard successMessage != nil else { return }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
                successMessage = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .anchorEmailRebindSuccess)) { event in
                showingVerification = false
                successMessage = L10n.Email.text(event.userInfo?["changed"] as? Bool == true ? "changeSuccess" : "verifySuccess")
            }
    }
}

extension View {
    func emailVerificationReminder() -> some View { modifier(EmailRiskModifier()) }
}
