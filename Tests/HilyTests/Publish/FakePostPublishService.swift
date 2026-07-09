import Foundation

/// 单测用 mock，实现 `PostPublishServiceProtocol`（Step 5 重构后只留 `createPost`）。
final class FakePostPublishService: PostPublishServiceProtocol {

    // MARK: - 注入

    var createResult: Result<Void, Error> = .success(())

    // MARK: - 记录

    private(set) var createCalls: [(textContent: String, imgUrls: [String])] = []

    // MARK: - 行为

    func createPost(textContent: String, imgUrls: [String]) async throws {
        createCalls.append((textContent, imgUrls))
        switch createResult {
        case .success: return
        case .failure(let err): throw err
        }
    }
}

/// 单测用 mock，实现 `OssCredentialServiceProtocol`（Step 5 重构后从 PostPublishService 抽出）。
final class FakeOssCredentialService: OssCredentialServiceProtocol {

    // MARK: - 注入

    /// 多次 getOssUploadParam 调用的结果序列。
    /// 若只设 1 个，所有调用都用这个；若多个，按顺序返回（用于 R19 重拉测试）。
    var results: [Result<OssCredential, Error>] = [
        .success(OssCredential.fixture(future: 7200))
    ]

    // MARK: - 记录

    private(set) var calls: Int = 0

    // MARK: - 行为

    func getOssUploadParam() async throws -> OssCredential {
        let idx = min(calls, results.count - 1)
        calls += 1
        switch results[idx] {
        case .success(let cred): return cred
        case .failure(let err): throw err
        }
    }
}

/// 测试 fixture for OssCredential
extension OssCredential {
    /// 默认未过期凭证。`future` 是相对当前 +N 秒的过期时间。
    static func fixture(future: TimeInterval = 7200) -> OssCredential {
        let expireEpoch = Int(Date().timeIntervalSince1970 + future)
        return OssCredential(
            accessid: "TEST_ACCESS_ID",
            policy: "TEST_POLICY_BASE64",
            signature: "TEST_SIGNATURE",
            host: "https://test-bucket.oss-test.example.com",
            cdnUrl: "https://test-cdn.example.com",
            expire: String(expireEpoch)
        )
    }

    /// 已过期凭证（用于 R18 预检测试）
    static var expired: OssCredential {
        OssCredential(
            accessid: "EXPIRED",
            policy: "p",
            signature: "s",
            host: "https://x.example.com",
            cdnUrl: "https://x.example.com",
            expire: "1"  // 1970 已远过期
        )
    }
}
