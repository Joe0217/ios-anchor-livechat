import Foundation

/// 单测用 mock，实现 `OssUploadServiceProtocol`。
///
/// 用法：注入 results 数组，按调用顺序消耗。
/// ```
/// let fake = FakeOssUploadService()
/// fake.results = [.success("url1"), .failure(OssUploadError.network), .success("url3")]
/// ```
final class FakeOssUploadService: OssUploadServiceProtocol {

    // MARK: - 注入

    /// 按调用顺序消耗。超过数组长度的调用 fallback 到 lastResult。
    var results: [Result<String, Error>] = []
    /// 当 results 耗尽时的兜底（默认 success "fallback-url"）
    var fallbackResult: Result<String, Error> = .success("fallback-url")

    /// 模拟上传延迟（秒）；> 0 时让 Task 有时间被 cancel
    var delaySeconds: Double = 0

    // MARK: - 记录

    private(set) var uploadCalls: [(objectKey: String, accessid: String, byteCount: Int)] = []

    func uploadImage(imageData: Data,
                     credential: OssCredential,
                     objectKey: String) async throws -> String {
        try await consume(objectKey: objectKey, credential: credential, byteCount: imageData.count)
    }

    func uploadVideo(videoData: Data,
                     credential: OssCredential,
                     objectKey: String,
                     contentType: String) async throws -> String {
        try await consume(objectKey: objectKey, credential: credential, byteCount: videoData.count)
    }

    private func consume(objectKey: String, credential: OssCredential, byteCount: Int) async throws -> String {
        uploadCalls.append((objectKey: objectKey,
                            accessid: credential.accessid,
                            byteCount: byteCount))
        if delaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }
        let idx = uploadCalls.count - 1
        let result: Result<String, Error>
        if idx < results.count {
            result = results[idx]
        } else {
            result = fallbackResult
        }
        switch result {
        case .success(let url): return url
        case .failure(let err): throw err
        }
    }
}
