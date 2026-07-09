import Foundation

/// OSS multipart/form-data body 拼装器（J spec §3.2 + INV2；H-2 v2 参数化）。
///
/// **职责**：纯逻辑函数式拼装；输入 credential + objectKey + fileData + contentType + acl → 输出 (body, contentType)。
/// 不发请求，不依赖网络层；让 `OssMultipartBodyBuilderTests` 能用金标 hex dump 严格比对。
///
/// **严格合约**（红队 #1 #2 critical）：
/// - 所有换行 `\r\n`（CRLF），无 `\n`
/// - boundary 字符集 `[A-Za-z0-9]{32}`（避免 `=` / `+` / `/` 被代理误解）
/// - 字段顺序：key → policy → Signature → OSSAccessKeyId → success_action_status → [x-oss-object-acl?] → file（**file 必须最后**）
/// - file part 必含 `Content-Disposition: form-data; name="file"; filename="<key 后缀>"`（缺会触发 400 InvalidArgument）
/// - file part 必含 `Content-Type: <contentType>`（图片 `image/jpeg` / 视频 `video/mp4` 等）
/// - 文本 part 不需要 Content-Type
/// - 每 part 之间 `\r\n--<boundary>\r\n`
/// - 终止 `\r\n--<boundary>--\r\n`（含 trailing CRLF）
///
/// **H-2 v2 变更**（uploadVideo.vue:139-143）：私密视频上传必须传 `x-oss-object-acl: private`。
/// 图片路径（J 朋友圈 / 反馈 / 头像）保持默认参数不变（`image/jpeg` + 无 acl），行为兼容。
enum OssMultipartBodyBuilder {

    /// 构造结果：HTTP body + Content-Type header（含 boundary）。
    struct Output {
        let body: Data
        let contentType: String  // 形如 "multipart/form-data; boundary=<boundary>"
    }

    /// 构造 multipart body。
    /// - parameter credential: OSS 凭证（提供 policy/signature/accessid）
    /// - parameter objectKey: OSS object key，形如 `00000000/20260626/<UUID>.jpg`（或 `.mp4`）
    /// - parameter fileData: 文件二进制（图片=压缩 JPEG / 视频=原始 mp4）
    /// - parameter contentType: 文件 MIME（默认 `image/jpeg` 兼容 J 朋友圈；视频传 `video/mp4`）
    /// - parameter objectAcl: OSS ACL（nil=默认桶策略；私密视频传 `"private"`）
    /// - parameter boundary: 调用方注入便于单测金标；生产用 `generateBoundary()`
    static func build(credential: OssCredential,
                      objectKey: String,
                      fileData: Data,
                      contentType: String = "image/jpeg",
                      objectAcl: String? = nil,
                      boundary: String) -> Output {
        var body = Data()
        let filename = (objectKey as NSString).lastPathComponent  // "<UUID>.jpg" / "<UUID>.mp4"

        // 字段顺序固定（OSS 文档要求 file 最后）
        body.append(textPart(boundary: boundary, name: "key", value: objectKey))
        body.append(textPart(boundary: boundary, name: "policy", value: credential.policy))
        body.append(textPart(boundary: boundary, name: "Signature", value: credential.signature))
        body.append(textPart(boundary: boundary, name: "OSSAccessKeyId", value: credential.accessid))
        body.append(textPart(boundary: boundary, name: "success_action_status", value: "200"))
        if let acl = objectAcl {
            // uploadVideo.vue:139-143 视频强制 acl=private
            body.append(textPart(boundary: boundary, name: "x-oss-object-acl", value: acl))
        }
        body.append(filePart(boundary: boundary, filename: filename, fileData: fileData, contentType: contentType))

        // 终止 boundary（含 trailing CRLF）
        body.append("--\(boundary)--\r\n")

        return Output(body: body,
                      contentType: "multipart/form-data; boundary=\(boundary)")
    }

    /// J 朋友圈调用 shim：老签名不变（图片路径），内部委托新签名。
    static func build(credential: OssCredential,
                      objectKey: String,
                      imageData: Data,
                      boundary: String) -> Output {
        build(credential: credential, objectKey: objectKey,
              fileData: imageData, contentType: "image/jpeg", objectAcl: nil,
              boundary: boundary)
    }

    /// 生成 32 字符 boundary，限定字符集 `[A-Za-z0-9]`。
    /// 注：纯随机性，不需要密码学安全。
    static func generateBoundary() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<32).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    // MARK: - Internals

    private static func textPart(boundary: String, name: String, value: String) -> Data {
        var part = Data()
        part.append("--\(boundary)\r\n")
        part.append("Content-Disposition: form-data; name=\"\(name)\"\r\n")
        part.append("\r\n")
        part.append(value)
        part.append("\r\n")
        return part
    }

    private static func filePart(boundary: String, filename: String, fileData: Data, contentType: String) -> Data {
        var part = Data()
        part.append("--\(boundary)\r\n")
        // 必含 filename（红队 #1 critical：缺会 400）
        part.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        // 必含 Content-Type（图片 image/jpeg；视频 video/mp4 等）
        part.append("Content-Type: \(contentType)\r\n")
        part.append("\r\n")
        part.append(fileData)
        part.append("\r\n")
        return part
    }
}

private extension Data {
    /// 便利：String → UTF-8 Data 追加。
    /// 失败应不可能（CRLF / ASCII headers / Base64 policy 都是 UTF-8 合法）。
    mutating func append(_ s: String) {
        if let d = s.data(using: .utf8) {
            self.append(d)
        }
    }
}
