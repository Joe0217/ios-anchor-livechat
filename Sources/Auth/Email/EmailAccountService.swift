import Foundation

/// DM-20260731-001: registration and authenticated rebind have separate tickets.
enum EmailAccountRules {
    static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "[\\p{C}\\p{Z}]", with: "", options: .regularExpression)
    }
    static func normalized(_ value: String) -> String { clean(value).lowercased() }
    static func validEmail(_ value: String) -> Bool {
        let email = clean(value)
        return email.count <= 100 && email.range(of: "^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\\.[A-Za-z]{2,}$", options: .regularExpression) != nil
    }
    static func validNewPassword(_ value: String) -> Bool { (8...20).contains(value.count) }
    static func validLoginPassword(_ value: String) -> Bool { (6...20).contains(value.count) }
    static func digits(_ value: String) -> String {
        String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
    }
    static let handledCodes: Set<String> = ["1039", "1042", "1046", "1087", "1088", "1100", "2016", "2084", "2085", "2086", "2087", "2088", "2089"]
}

struct AnchorEmailInfo: Decodable, Equatable {
    let email: String?
    let realEmailVerified: Int
    var isVerified: Bool { realEmailVerified == 1 }

    enum CodingKeys: String, CodingKey { case email, realEmailVerified }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        if let number = try? c.decode(Int.self, forKey: .realEmailVerified) {
            realEmailVerified = number
        } else {
            realEmailVerified = Int((try? c.decode(String.self, forKey: .realEmailVerified)) ?? "") ?? 0
        }
    }
}

struct EmailVerificationTicket: Decodable {
    let ticket: String
    let rebindType: Int?
}

protocol EmailAccountServicing {
    func current() async throws -> AnchorEmailInfo?
    func sendCode(email: String, rebind: Bool) async throws
    func verifyCode(email: String, code: String, rebind: Bool) async throws -> EmailVerificationTicket
    func feedback(email: String, content: String) async throws
    func submit(ticket: String, password: String) async throws -> String
}

struct EmailAccountService: EmailAccountServicing {
    let client: APIClient
    init(client: APIClient = .shared) { self.client = client }

    func current() async throws -> AnchorEmailInfo? {
        let data = try await client.post("/api/anchor/email/current", suppressCodes: ["*"])
        return try JSONDecoder().decode(AnchorEmailInfo?.self, from: data)
    }
    func sendCode(email: String, rebind: Bool) async throws {
        _ = try await client.post(rebind ? "/api/anchor/email/rebind/sendCode" : "/api/login/email/sendCode",
                                  body: ["email": EmailAccountRules.normalized(email)],
                                  token: rebind ? nil : "", suppressCodes: EmailAccountRules.handledCodes)
    }
    func verifyCode(email: String, code: String, rebind: Bool) async throws -> EmailVerificationTicket {
        let data = try await client.post(rebind ? "/api/anchor/email/rebind/verifyCode" : "/api/login/email/verifyCode",
                                         body: ["email": EmailAccountRules.normalized(email), "code": code],
                                         token: rebind ? nil : "", suppressCodes: EmailAccountRules.handledCodes)
        let result = try JSONDecoder().decode(EmailVerificationTicket.self, from: data)
        guard !result.ticket.isEmpty, !rebind || [1, 2].contains(result.rebindType ?? 0) else {
            throw APIError(code: "-1", message: "Invalid email verification response")
        }
        return result
    }
    func feedback(email: String, content: String) async throws {
        _ = try await client.post("/api/login/email/codeFeedback", body: ["email": EmailAccountRules.normalized(email), "content": content],
                                  token: "", suppressCodes: EmailAccountRules.handledCodes)
    }
    func submit(ticket: String, password: String) async throws -> String {
        let encrypted = CryptoUtil.loginPassword(password)
        let data = try await client.post("/api/anchor/email/rebind/submit",
                                         body: ["ticket": ticket, "password": encrypted, "confirmPassword": encrypted],
                                         suppressCodes: EmailAccountRules.handledCodes)
        // APIClient returns decrypted payloads; deployments may return a JSON string or plain text.
        let token = (try? JSONDecoder().decode(String.self, from: data))
            ?? String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty, token != "null", !token.hasPrefix("{"), !token.hasPrefix("[") else {
            throw APIError(code: "-1", message: "Invalid refreshed session")
        }
        return token
    }
}

extension Notification.Name {
    static let anchorEmailRebindSuccess = Notification.Name("anchorEmailRebindSuccess")
}
