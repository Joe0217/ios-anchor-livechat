// Standalone macOS test doubles. Production EmailAccountService/Store are compiled unchanged.
import Foundation

struct APIError: Error { let code: String; let message: String }
final class APIClient {
    static let shared = APIClient()
    struct Request { let path: String; let body: [String: Any]?; let token: String?; let suppressed: Set<String> }
    var requests: [Request] = []
    var response = Data("null".utf8)
    func post(_ path: String, body: [String: Any]? = nil, token: String? = nil, suppressCodes: Set<String> = []) async throws -> Data {
        requests.append(Request(path: path, body: body, token: token, suppressed: suppressCodes))
        return response
    }
}
enum CryptoUtil {
    // Real double-MD5 is separately covered by CryptoUtilTests in the app's unit target.
    static func loginPassword(_ value: String) -> String { "hashed:" + value }
}
struct HarnessUser { var userId: Int? = 1 }
@MainActor
final class SessionStore {
    static let shared = SessionStore()
    var sessionGeneration = UUID()
    var user: HarnessUser? = HarnessUser()
    var updatedEmail: String?
    func applyEmailRebind(token: String, email: String, password: String, expectedGeneration: UUID) throws {
        guard expectedGeneration == sessionGeneration else { throw CancellationError() }
        updatedEmail = email
    }
}
enum GlobalErrorBannerNotify {
    static func isCancellation(_ error: Error) -> Bool { error is CancellationError }
}
enum L10n {
    enum Email {
        static func text(_ key: String) -> String { key }
        static func error(_ error: Error) -> String { (error as? APIError)?.code ?? "networkError" }
    }
}
final class FakeEmailService: EmailAccountServicing {
    var currentData = Data("{\"email\":\"owner@example.com\",\"realEmailVerified\":0}".utf8)
    var sends = 0
    var verifies = 0
    var submissions = 0
    var feedbacks = 0
    var failure: Error?
    var pauseSend: CheckedContinuation<Void, Never>?
    var suspends = false
    var ticketType = 1
    func current() async throws -> AnchorEmailInfo? {
        if let failure { throw failure }
        return try JSONDecoder().decode(AnchorEmailInfo?.self, from: currentData)
    }
    func sendCode(email: String, rebind: Bool) async throws {
        sends += 1
        if suspends { await withCheckedContinuation { pauseSend = $0 } }
        if let failure { throw failure }
    }
    func verifyCode(email: String, code: String, rebind: Bool) async throws -> EmailVerificationTicket {
        verifies += 1
        if let failure { throw failure }
        return EmailVerificationTicket(ticket: "fixture-ticket", rebindType: rebind ? ticketType : nil)
    }
    func feedback(email: String, content: String) async throws {
        feedbacks += 1
        if let failure { throw failure }
    }
    func submit(ticket: String, password: String) async throws -> String {
        submissions += 1
        if let failure { throw failure }
        return "fixture-session"
    }
}
