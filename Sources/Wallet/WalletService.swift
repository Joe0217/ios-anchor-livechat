import CommonCrypto
import Foundation
import os

enum WalletServiceError: Error, LocalizedError {
    case invalidResponse
    case missingSession
    case invalidOSSHost
    case uploadFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "wallet response could not be decoded"
        case .missingSession: return "wallet requires a signed-in account"
        case .invalidOSSHost: return "face upload host is invalid"
        case .uploadFailed(let status): return "face upload failed with HTTP \(status)"
        }
    }
}

protocol WalletServicing {
    func fetchSummary() async throws -> WalletSummary
    func fetchLedger(filter: WalletLedgerFilter, page: Int, pageSize: Int) async throws -> [WalletLedgerEntry]
    func fetchWithdrawalWallet() async throws -> WithdrawalWallet
    func fetchAccounts() async throws -> [WithdrawalAccount]
    func addAccount(type: String, address: String, name: String) async throws
    func removeAccount(id: String) async throws
    func fetchPasswordConfig() async throws -> WithdrawalPasswordConfig
    func setWithdrawalPassword(_ password: String) async throws
    func submitWithdrawal(account: WithdrawalAccount, diamondAmount: Int64, password: String) async throws
    func fetchRecords() async throws -> [WithdrawalRecord]
    func requiresFaceVerification(anchorID: Int) async throws -> Bool
    func verifyFace(jpegData: Data, anchorID: Int) async throws
}

final class WalletService: WalletServicing {
    static let shared = WalletService()

    private let logger = Logger(subsystem: "com.anchor.livechat", category: "Wallet")
    private let ossUploader: WalletOSSUploader

    init(ossUploader: WalletOSSUploader = WalletOSSUploader()) {
        self.ossUploader = ossUploader
    }

    func fetchSummary() async throws -> WalletSummary {
        WalletSummary(object: try WalletJSON.object(from: await APIClient.shared.post("/api/wallet/anchor/flowList/myBalance", body: [:])))
    }

    func fetchLedger(filter: WalletLedgerFilter, page: Int, pageSize: Int) async throws -> [WalletLedgerEntry] {
        let anchorID = await MainActor.run { SessionStore.shared.user?.userId }
        guard let anchorID else { throw WalletServiceError.missingSession }
        let data = try await PartyAPIClient.shared.post(
            "/sapi/anchor/v1/client/anchor/bill/list",
            body: [
                "pageIndex": page,
                "pageSize": pageSize,
                "type": filter.sapiValue,
                "anchorId": anchorID,
                "needTotalCount": false,
            ]
        )
        return try WalletJSON.array(from: data).enumerated().map { WalletLedgerEntry(object: $0.element, index: $0.offset) }
    }

    func fetchWithdrawalWallet() async throws -> WithdrawalWallet {
        WithdrawalWallet(object: try WalletJSON.object(from: await APIClient.shared.post("/api/wallet/anchor/myWallet", body: [:])))
    }

    func fetchAccounts() async throws -> [WithdrawalAccount] {
        let data = try await APIClient.shared.post("/api/wallet/anchor/withdrawAccountList", body: [:])
        return try WalletJSON.array(from: data).compactMap(WithdrawalAccount.init(object:))
    }

    func addAccount(type: String, address: String, name: String) async throws {
        _ = try await APIClient.shared.post(
            "/api/wallet/anchor/addWithdrawAccount",
            body: ["accountType": type, "accountAddress": address, "accountName": name]
        )
    }

    func removeAccount(id: String) async throws {
        _ = try await APIClient.shared.post("/api/wallet/anchor/delWithdrawAccount", body: ["id": id])
    }

    func fetchPasswordConfig() async throws -> WithdrawalPasswordConfig {
        WithdrawalPasswordConfig(object: try WalletJSON.object(from: await APIClient.shared.post("/api/wallet/getAnchorWithDrawConfig", body: [:])))
    }

    func setWithdrawalPassword(_ password: String) async throws {
        _ = try await APIClient.shared.post("/api/wallet/setWithdrawPassWord", body: ["password": password])
    }

    func submitWithdrawal(account: WithdrawalAccount, diamondAmount: Int64, password: String) async throws {
        guard ["Digifinex", "USDT", "Epay"].contains(account.type),
              password.utf8.count == 6,
              password.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw WalletServiceError.invalidResponse
        }
        _ = try await APIClient.shared.post(
            "/api/wallet/applyWithdrawV2",
            body: [
                "accountAddress": account.address,
                "accountName": account.name,
                "accountType": account.type,
                "withdrawNum": diamondAmount,
                "password": password,
            ]
        )
    }

    func fetchRecords() async throws -> [WithdrawalRecord] {
        let data = try await APIClient.shared.post("/api/wallet/withdrawRecord", body: [:])
        return try WalletJSON.array(from: data).enumerated().map { WithdrawalRecord(object: $0.element, index: $0.offset) }
    }

    func requiresFaceVerification(anchorID: Int) async throws -> Bool {
        let data = try await APIClient.shared.post(
            "/api/face/auth/verified",
            body: ["deviceId": DeviceInfo.deviceId, "anchorId": anchorID]
        )
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let value = WalletJSON.bool(raw) else { throw WalletServiceError.invalidResponse }
        return value
    }

    func verifyFace(jpegData: Data, anchorID: Int) async throws {
        let credential = try await fetchFaceCredential()
        let objectKey = "avatar_\(Int(Date().timeIntervalSince1970 * 1_000)).jpg"
        let imageURL = try await ossUploader.upload(jpegData: jpegData, credential: credential, objectKey: objectKey)
        _ = try await APIClient.shared.post(
            "/api/face/auth/scan",
            body: ["deviceId": DeviceInfo.deviceId, "anchorId": anchorID, "imgUrl": imageURL.absoluteString]
        )
        logger.info("face verification accepted")
    }

    private func fetchFaceCredential() async throws -> WalletOSSCredential {
        // H5 invokes this exact STS endpoint with GET. It is distinct from the app's
        // PostObject credential endpoint and must not be substituted.
        let data = try await APIClient.shared.get("/sts/getkey")
        return try WalletOSSCredential(object: WalletJSON.object(from: data))
    }
}

struct WalletOSSCredential {
    let host: URL
    let bucket: String
    let accessKeyID: String
    let accessKeySecret: String
    let securityToken: String

    init(object: [String: Any]) throws {
        guard let hostString = WalletJSON.string(object["host"]) else {
            throw WalletServiceError.invalidOSSHost
        }
        let normalized = hostString.contains("://") ? hostString : "https://\(hostString)"
        guard var components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw WalletServiceError.invalidOSSHost
        }
        // The H5 client always passes `secure: true`; normalize legacy HTTP host
        // values before signing so the temporary credential never travels in clear text.
        components.scheme = "https"
        guard let host = components.url,
              let hostname = host.host?.lowercased(),
              hostname.hasSuffix(".aliyuncs.com"),
              let bucket = hostname.split(separator: ".").first, !bucket.isEmpty,
              let accessKeyID = WalletJSON.string(object["AccessKeyId"]), !accessKeyID.isEmpty,
              let accessKeySecret = WalletJSON.string(object["AccessKeySecret"]), !accessKeySecret.isEmpty,
              let securityToken = WalletJSON.string(object["SecurityToken"]), !securityToken.isEmpty else {
            throw WalletServiceError.invalidOSSHost
        }
        self.host = host
        self.bucket = String(bucket)
        self.accessKeyID = accessKeyID
        self.accessKeySecret = accessKeySecret
        self.securityToken = securityToken
    }
}

final class WalletOSSUploader {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func upload(jpegData: Data, credential: WalletOSSCredential, objectKey: String) async throws -> URL {
        guard !jpegData.isEmpty,
              !objectKey.isEmpty,
              !objectKey.contains("..") else {
            throw WalletServiceError.invalidOSSHost
        }

        let date = Self.rfc1123Date()
        let resource = "/\(credential.bucket)/\(objectKey)"
        let canonicalHeaders = "x-oss-security-token:\(credential.securityToken)\n"
        let stringToSign = "PUT\n\nimage/jpeg\n\(date)\n\(canonicalHeaders)\(resource)"
        let signature = Self.hmacSHA1Base64(key: credential.accessKeySecret, value: stringToSign)

        let objectURL = credential.host.appendingPathComponent(objectKey)
        var request = URLRequest(url: objectURL)
        request.httpMethod = "PUT"
        request.timeoutInterval = 30
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(date, forHTTPHeaderField: "Date")
        request.setValue(credential.securityToken, forHTTPHeaderField: "x-oss-security-token")
        request.setValue("OSS \(credential.accessKeyID):\(signature)", forHTTPHeaderField: "Authorization")
        request.httpBody = jpegData

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw WalletServiceError.uploadFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return objectURL
    }

    private static func rfc1123Date() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date())
    }

    private static func hmacSHA1Base64(key: String, value: String) -> String {
        let keyData = Data(key.utf8)
        let valueData = Data(value.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        keyData.withUnsafeBytes { keyBuffer in
            valueData.withUnsafeBytes { valueBuffer in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA1),
                    keyBuffer.baseAddress,
                    keyData.count,
                    valueBuffer.baseAddress,
                    valueData.count,
                    &digest
                )
            }
        }
        return Data(digest).base64EncodedString()
    }
}
