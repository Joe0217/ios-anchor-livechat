import Foundation
import Combine

@MainActor
final class EmailAccountStore: ObservableObject {
    enum Mode { case registration, verify, change }
    enum Step { case email, code, password, complete }
    @Published var email: String
    @Published var code = ""
    @Published var password = ""
    @Published var confirmation = ""
    @Published private(set) var step: Step = .email
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    @Published private(set) var currentIsReadOnly = false
    @Published private(set) var remaining = 0
    @Published private(set) var ticketRemaining = 0
    @Published var message: String?
    @Published private(set) var cursorVisible = true
    @Published var mismatch = false
    @Published var confirmChange = false
    @Published var confirmExit = false
    @Published var returnToLogin = false
    @Published var alreadyVerified = false
    private(set) var ticket = ""
    private(set) var ticketExpiresAt: Date?
    private(set) var didChangeEmail = false
    let mode: Mode
    private let service: EmailAccountServicing
    private let now: () -> Date
    private var resendAt: Date?
    private var resendEmail: String?
    private let ownerGeneration: UUID
    private let ownerID: Int?
    private var active = true
    var rebind: Bool { mode != .registration }
    var canSubmitPassword: Bool { EmailAccountRules.validNewPassword(password) && !confirmation.isEmpty && !busy }

    init(mode: Mode, email: String = "", service: EmailAccountServicing = EmailAccountService(), now: @escaping () -> Date = Date.init) {
        self.mode = mode
        self.email = EmailAccountRules.clean(email)
        self.service = service
        self.now = now
        ownerGeneration = SessionStore.shared.sessionGeneration
        ownerID = SessionStore.shared.user?.userId
    }

    private var isCurrent: Bool {
        active && !Task.isCancelled && SessionStore.shared.sessionGeneration == ownerGeneration
            && (!rebind || SessionStore.shared.user?.userId == ownerID)
    }
    func deactivate() { active = false; password = ""; confirmation = ""; ticket = "" }

    func load() async {
        guard !loaded, !busy else { return }
        guard mode == .verify else { loaded = true; return }
        busy = true
        defer { busy = false }
        do {
            let info = try await service.current()
            guard isCurrent else { return }
            guard let info else { message = L10n.Email.text("loadFailed"); return }
            if mode == .verify {
                if info.isVerified {
                    alreadyVerified = true
                    message = L10n.Email.text("alreadyVerified")
                } else if let original = info.email, !EmailAccountRules.clean(original).isEmpty {
                    email = EmailAccountRules.clean(original)
                    currentIsReadOnly = true
                } else {
                    email = ""
                    message = L10n.Email.text("missingEmail")
                }
            }
            loaded = true
        } catch { handle(error) }
    }

    func useNewEmail() {
        guard !busy else { return }
        currentIsReadOnly = false
        email = ""
        code = ""
        step = .email
        ticket = ""
        ticketExpiresAt = nil
        message = L10n.Email.text("resetNotice")
    }

    func requestCode() async {
        guard loaded, !busy, isCurrent else { return }
        email = EmailAccountRules.clean(email)
        guard EmailAccountRules.validEmail(email) else { message = L10n.Email.text("invalidEmail"); return }
        if rebind && !currentIsReadOnly { confirmChange = true; return }
        await sendCode()
    }

    func sendCode() async {
        guard !busy, isCurrent else { return }
        guard EmailAccountRules.validEmail(email) else { message = L10n.Email.text("invalidEmail"); return }
        // The deadline survives step changes and app backgrounding.
        // The cooldown belongs to the normalized address, not to the current page.
        // Returning to the email step must not allow bypassing the server rate limit.
        if let resendEmail, resendEmail == EmailAccountRules.normalized(email),
           let resendAt, resendAt > now() { return }
        busy = true
        message = nil
        let requestedEmail = EmailAccountRules.normalized(email)
        defer { busy = false }
        do {
            try await service.sendCode(email: requestedEmail, rebind: rebind)
            guard isCurrent else { return }
            email = requestedEmail
            resendAt = now().addingTimeInterval(60)
            resendEmail = requestedEmail
            remaining = 60
            code = ""
            step = .code
            message = L10n.Email.text("codeSent")
        } catch { handle(error) }
    }

    func enterCode(_ value: String) {
        guard !busy else { return }
        code = EmailAccountRules.digits(value)
        if code.count == 6 { Task { await verify() } }
    }

    func verify() async {
        guard !busy, code.count == 6, step == .code, isCurrent else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            let result = try await service.verifyCode(email: email, code: code, rebind: rebind)
            guard isCurrent else { return }
            ticket = result.ticket
            didChangeEmail = result.rebindType == 2
            ticketExpiresAt = now().addingTimeInterval(rebind ? 600 : 3600)
            ticketRemaining = rebind ? 600 : 3600
            code = ""
            password = ""
            confirmation = ""
            step = .password
        } catch {
            code = ""
            handle(error)
        }
    }

    func acceptPassword() async {
        guard !busy, isCurrent else { return }
        guard EmailAccountRules.validNewPassword(password) else { message = L10n.Email.text("passwordRule"); return }
        mismatch = password != confirmation
        guard !mismatch else { return }
        guard let expiry = ticketExpiresAt, expiry > now(), !ticket.isEmpty else { expire(); return }
        guard rebind else { step = .complete; return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            let token = try await service.submit(ticket: ticket, password: password)
            guard isCurrent else { return }
            try SessionStore.shared.applyEmailRebind(token: token, email: email, password: password, expectedGeneration: ownerGeneration)
            ticket = ""
            password = ""
            confirmation = ""
            step = .complete
            NotificationCenter.default.post(name: .anchorEmailRebindSuccess, object: nil,
                                             userInfo: ["changed": didChangeEmail])
        } catch { handle(error) }
    }

    func sendFeedback(_ content: String) async -> Bool {
        guard !busy, isCurrent else { return false }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (5...200).contains(text.count) else { message = L10n.Email.text("feedbackRule"); return false }
        busy = true
        defer { busy = false }
        do {
            try await service.feedback(email: email, content: text)
            guard isCurrent else { return false }
            message = L10n.Email.text("feedbackSent")
            return true
        } catch { handle(error); return false }
    }

    func back() {
        guard !busy else { return }
        if step == .password && rebind { confirmExit = true; return }
        step = .email
        ticket = ""
        ticketExpiresAt = nil
        password = ""
        confirmation = ""
        code = ""
    }

    func tick() {
        cursorVisible.toggle()
        remaining = max(0, Int(ceil(resendAt?.timeIntervalSince(now()) ?? 0)))
        ticketRemaining = max(0, Int(ceil(ticketExpiresAt?.timeIntervalSince(now()) ?? 0)))
        if step == .password, ticketRemaining == 0, !busy { expire() }
    }
    func runClock() async {
        while !Task.isCancelled {
            tick()
            do { try await Task.sleep(nanoseconds: 1_000_000_000) }
            catch { return } // View lifecycle cancels the clock.
        }
    }
    private func expire() {
        ticket = ""
        ticketExpiresAt = nil
        password = ""
        confirmation = ""
        code = ""
        step = .email
        message = L10n.Email.text("expired")
    }
    private func handle(_ error: Error) {
        guard isCurrent, !GlobalErrorBannerNotify.isCancellation(error) else { return }
        if let api = error as? APIError {
            if api.code == "2084" { expire(); return }
            if api.code == "1087", !rebind { returnToLogin = true }
            if api.code == "1039" {
                resendAt = now().addingTimeInterval(60)
                resendEmail = EmailAccountRules.normalized(email)
                remaining = 60
            }
        }
        message = L10n.Email.error(error)
    }
}
