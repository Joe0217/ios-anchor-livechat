import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "OssCredentialService")

/// OSS 凭证服务真实现 —— 通用能力（Sources/Core/Upload/）。
///
/// **path**：`/sts/getOssUploadParam`（无 `/api/` 前缀，STS 服务独立网关）
/// 参考 [h5-blueprint-source memory](../../../../.claude/projects/-Users-joe-Desktop-HN-ios-anchor-livechat/memory/h5-blueprint-source.md)
/// 关于 STS `/sts/*` vs 业务 `/api/*` 的前缀区别。
///
/// 走主接口加密通道（AES + 双 token + envelope）。
final class OssCredentialService: OssCredentialServiceProtocol {

    static let shared = OssCredentialService()

    private init() {}

    func getOssUploadParam() async throws -> OssCredential {
        let data = try await APIClient.shared.post("/sts/getOssUploadParam", body: [:])
        do {
            let cred = try JSONDecoder().decode(OssCredential.self, from: data)
            logger.info("getOssUploadParam ok host=\(cred.host, privacy: .public)")
            return cred
        } catch {
            logger.error("getOssUploadParam decode failed: \(String(describing: error))")
            throw error
        }
    }
}
