import Foundation

@main
struct EmailAccountChecks {
    @MainActor
    static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label)
            checks += 1
        }
        expect(EmailAccountRules.clean(" \u{200f}A@Example.com\n") == "A@Example.com", "RTL/control cleanup")
        expect(EmailAccountRules.normalized("A@Example.com") == "a@example.com", "canonical email")
        expect(EmailAccountRules.validEmail("a+b@example.com"), "email plus addressing")
        expect(!EmailAccountRules.validEmail("broken@"), "invalid address")
        expect(!EmailAccountRules.validEmail(String(repeating: "a", count: 101) + "@example.com"), "email maximum")
        expect(EmailAccountRules.validLoginPassword("123456"), "legacy six-character login")
        expect(!EmailAccountRules.validNewPassword("1234567"), "new password minimum")
        expect(EmailAccountRules.validNewPassword(String(repeating: "x", count: 20)), "new password maximum")
        expect(!EmailAccountRules.validLoginPassword(String(repeating: "x", count: 21)), "login maximum")
        expect(EmailAccountRules.digits("12a٣45678") == "124567", "ASCII code filtering")

        let api = APIClient()
        let service = EmailAccountService(client: api)
        try await service.sendCode(email: "A@Example.com", rebind: false)
        expect(api.requests.last?.path == "/api/login/email/sendCode" && api.requests.last?.token == "", "anonymous registration send")
        try await service.sendCode(email: "a@example.com", rebind: true)
        expect(api.requests.last?.path == "/api/anchor/email/rebind/sendCode" && api.requests.last?.token == nil, "authenticated rebind send")
        api.response = Data("{\"ticket\":\"fixture\",\"rebindType\":2}".utf8)
        let verified = try await service.verifyCode(email: "a@example.com", code: "123456", rebind: true)
        expect(verified.rebindType == 2, "authoritative rebindType")
        api.response = Data("{\"ticket\":\"\"}".utf8)
        do { _ = try await service.verifyCode(email: "a@example.com", code: "123456", rebind: false); preconditionFailure("empty ticket accepted") }
        catch { checks += 1 }
        api.response = Data("\"fixture-session\"".utf8)
        _ = try await service.submit(ticket: "fixture", password: "12345678")
        expect(api.requests.last?.body?["password"] as? String == api.requests.last?.body?["confirmPassword"] as? String, "equal encrypted passwords")
        expect(api.requests.last?.body?["password"] as? String != "12345678", "no plaintext password submission")
        api.response = Data("null".utf8)
        do { _ = try await service.submit(ticket: "fixture", password: "12345678"); preconditionFailure("null token accepted") }
        catch { checks += 1 }
        let nullInfo = try await service.current()
        expect(nullInfo == nil, "null current email")
        try await service.feedback(email: "a@example.com", content: "Code missing")
        expect(api.requests.last?.token == "" && api.requests.last?.path == "/api/login/email/codeFeedback", "anonymous feedback reuse")

        var date = Date(timeIntervalSince1970: 1000)
        let fake = FakeEmailService()
        let registration = EmailAccountStore(mode: .registration, email: "A@example.com", service: fake, now: { date })
        await registration.load()
        await registration.requestCode()
        expect(fake.sends == 1 && registration.remaining == 60 && registration.step == .code, "single send on entry")
        await registration.sendCode()
        expect(fake.sends == 1, "cooldown disables resend")
        date = date.addingTimeInterval(61)
        registration.tick()
        expect(registration.remaining == 0, "wall-clock background countdown")
        registration.code = "123456"
        fake.failure = APIError(code: "1042", message: "error.code")
        await registration.verify()
        expect(registration.code.isEmpty && registration.step == .code, "failure clears all code cells")
        fake.failure = nil
        registration.code = "123456"
        await registration.verify()
        expect(registration.ticketRemaining == 3600 && registration.step == .password, "registration ticket TTL")
        registration.password = "12345678"
        registration.confirmation = "87654321"
        await registration.acceptPassword()
        expect(registration.mismatch && registration.step == .password, "confirmation blocks completion")
        registration.confirmation = "12345678"
        await registration.acceptPassword()
        expect(registration.step == .complete && fake.submissions == 0, "registration passes ticket to profile, not rebind")

        let rebind = EmailAccountStore(mode: .verify, service: fake, now: { date })
        await rebind.load()
        expect(rebind.currentIsReadOnly, "original address read-only")
        await rebind.requestCode()
        rebind.code = "123456"
        await rebind.verify()
        expect(rebind.ticketRemaining == 600, "rebind TTL")
        rebind.back()
        expect(rebind.confirmExit && rebind.step == .password, "password exit confirmation")
        date = date.addingTimeInterval(601)
        rebind.tick()
        expect(rebind.step == .email && rebind.ticket.isEmpty, "ticket expiry returns to send page")

        let change = EmailAccountStore(mode: .change, email: "new@example.com", service: fake)
        await change.load()
        let beforeSend = fake.sends
        await change.requestCode()
        expect(change.confirmChange && fake.sends == beforeSend, "new-address confirmation before sending")
        let sentShortFeedback = await change.sendFeedback("1234")
        expect(!sentShortFeedback && fake.feedbacks == 0, "feedback lower bound")
        let sentFeedback = await change.sendFeedback("Code missing")
        expect(sentFeedback && fake.feedbacks == 1, "feedback submission")
        fake.ticketType = 2
        await change.sendCode()
        change.code = "123456"
        await change.verify()
        change.password = "12345678"
        change.confirmation = "12345678"
        await change.acceptPassword()
        expect(change.step == .complete && change.didChangeEmail, "rebind success")
        expect(SessionStore.shared.updatedEmail == "new@example.com", "session update before completion")
        expect(change.password.isEmpty && change.ticket.isEmpty, "clear consumed secrets")

        let slow = FakeEmailService()
        slow.suspends = true
        let stale = EmailAccountStore(mode: .registration, email: "test@example.com", service: slow)
        await stale.load()
        let task = Task { await stale.requestCode() }
        while slow.pauseSend == nil { await Task.yield() }
        await stale.requestCode()
        expect(slow.sends == 1, "in-flight send lock")
        SessionStore.shared.sessionGeneration = UUID()
        slow.pauseSend?.resume()
        await task.value
        expect(stale.step == .email && stale.ticket.isEmpty, "old account response discarded")

        let exists = FakeEmailService()
        exists.failure = APIError(code: "1087", message: "email exists")
        let duplicate = EmailAccountStore(mode: .registration, email: "test@example.com", service: exists)
        await duplicate.load()
        await duplicate.requestCode()
        expect(duplicate.returnToLogin, "duplicate email routes to login")
        print("Email account checks passed: \(checks)")
    }
}
