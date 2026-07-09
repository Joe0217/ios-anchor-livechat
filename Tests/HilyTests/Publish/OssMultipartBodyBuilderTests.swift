import XCTest

/// OssMultipartBodyBuilder 严格合约金标测试（spec INV2 + 红队 #1 #2 critical）。
///
/// 验证：
/// - 字段顺序：key → policy → Signature → OSSAccessKeyId → success_action_status → file
/// - file part 必含 `Content-Disposition: filename="..."` + `Content-Type: image/jpeg`
/// - 文本 part 不含 Content-Type
/// - 所有换行严格 CRLF
/// - 终止 boundary 含 trailing CRLF
final class OssMultipartBodyBuilderTests: XCTestCase {

    /// 金标验证：手工构造期望 body 字节，OssMultipartBodyBuilder 输出必须完全一致。
    func test_build_producesGoldenMultipartBody() {
        let cred = OssCredential(
            accessid: "AID",
            policy: "POLICY_B64",
            signature: "SIG_B64",
            host: "https://x.example.com",
            cdnUrl: "https://cdn.example.com",
            expire: "9999999999"
        )
        let fileBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])  // JPEG 头 + 几字节
        let boundary = "TestBoundary0123456789abcdefghij"  // 32 字符 [A-Za-z0-9]
        let objectKey = "00000000/20260626/abc123.jpg"

        let out = OssMultipartBodyBuilder.build(
            credential: cred,
            objectKey: objectKey,
            imageData: fileBytes,
            boundary: boundary
        )

        // Content-Type header
        XCTAssertEqual(out.contentType, "multipart/form-data; boundary=\(boundary)")

        // 期望 body：完全按 OSS 文档手工拼，逐字节匹配
        var expected = Data()
        // key part
        expected.append(string: "--\(boundary)\r\n")
        expected.append(string: "Content-Disposition: form-data; name=\"key\"\r\n")
        expected.append(string: "\r\n")
        expected.append(string: "00000000/20260626/abc123.jpg")
        expected.append(string: "\r\n")
        // policy
        expected.append(string: "--\(boundary)\r\n")
        expected.append(string: "Content-Disposition: form-data; name=\"policy\"\r\n")
        expected.append(string: "\r\n")
        expected.append(string: "POLICY_B64")
        expected.append(string: "\r\n")
        // Signature
        expected.append(string: "--\(boundary)\r\n")
        expected.append(string: "Content-Disposition: form-data; name=\"Signature\"\r\n")
        expected.append(string: "\r\n")
        expected.append(string: "SIG_B64")
        expected.append(string: "\r\n")
        // OSSAccessKeyId
        expected.append(string: "--\(boundary)\r\n")
        expected.append(string: "Content-Disposition: form-data; name=\"OSSAccessKeyId\"\r\n")
        expected.append(string: "\r\n")
        expected.append(string: "AID")
        expected.append(string: "\r\n")
        // success_action_status
        expected.append(string: "--\(boundary)\r\n")
        expected.append(string: "Content-Disposition: form-data; name=\"success_action_status\"\r\n")
        expected.append(string: "\r\n")
        expected.append(string: "200")
        expected.append(string: "\r\n")
        // file part（必含 filename + Content-Type）
        expected.append(string: "--\(boundary)\r\n")
        expected.append(string: "Content-Disposition: form-data; name=\"file\"; filename=\"abc123.jpg\"\r\n")
        expected.append(string: "Content-Type: image/jpeg\r\n")
        expected.append(string: "\r\n")
        expected.append(fileBytes)
        expected.append(string: "\r\n")
        // 终止
        expected.append(string: "--\(boundary)--\r\n")

        XCTAssertEqual(out.body, expected, "金标 hex dump 不一致")
    }

    func test_build_fieldOrderIsFixed() {
        // 字段顺序：key 必在第一，file 必在最后（OSS 文档要求）
        let cred = OssCredential.fixture()
        let out = OssMultipartBodyBuilder.build(
            credential: cred,
            objectKey: "x.jpg",
            imageData: Data([0x00]),
            boundary: "Boundary00000000000000000000000Z"
        )
        let bodyString = String(data: out.body, encoding: .utf8) ?? ""
        let keyIdx = bodyString.range(of: "name=\"key\"")!.lowerBound
        let policyIdx = bodyString.range(of: "name=\"policy\"")!.lowerBound
        let sigIdx = bodyString.range(of: "name=\"Signature\"")!.lowerBound
        let accessIdx = bodyString.range(of: "name=\"OSSAccessKeyId\"")!.lowerBound
        let statusIdx = bodyString.range(of: "name=\"success_action_status\"")!.lowerBound
        let fileIdx = bodyString.range(of: "name=\"file\"")!.lowerBound

        XCTAssertLessThan(keyIdx, policyIdx)
        XCTAssertLessThan(policyIdx, sigIdx)
        XCTAssertLessThan(sigIdx, accessIdx)
        XCTAssertLessThan(accessIdx, statusIdx)
        XCTAssertLessThan(statusIdx, fileIdx)
    }

    func test_build_filePartContainsFilenameAndContentType() {
        let out = OssMultipartBodyBuilder.build(
            credential: OssCredential.fixture(),
            objectKey: "path/to/abc123.jpg",
            imageData: Data([0x00]),
            boundary: "Boundary00000000000000000000000Y"
        )
        let bodyString = String(data: out.body, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("filename=\"abc123.jpg\""),
                      "file part 必须含 filename（红队 #1 critical）")
        XCTAssertTrue(bodyString.contains("Content-Type: image/jpeg"),
                      "file part 必须含 Content-Type: image/jpeg（INV3）")
    }

    func test_build_terminatorHasTrailingCRLF() {
        let out = OssMultipartBodyBuilder.build(
            credential: OssCredential.fixture(),
            objectKey: "x.jpg",
            imageData: Data([0x00]),
            boundary: "B12345678901234567890123456789AB"
        )
        // body 末尾必须是 "--<boundary>--\r\n"
        let tail = "--B12345678901234567890123456789AB--\r\n".data(using: .utf8)!
        XCTAssertTrue(out.body.suffix(tail.count) == tail,
                      "终止 boundary 末尾必须含 trailing CRLF（红队 #2 critical）")
    }

    func test_build_textPartHasNoContentType() {
        // 文本 part 不应有 Content-Type header
        let out = OssMultipartBodyBuilder.build(
            credential: OssCredential.fixture(),
            objectKey: "x.jpg",
            imageData: Data([0x00]),
            boundary: "B12345678901234567890123456789CD"
        )
        let bodyString = String(data: out.body, encoding: .utf8) ?? ""
        // 抓 policy part：从 "name=\"policy\"" 到下一个 boundary
        let policyMarker = "name=\"policy\""
        let nextBoundary = "--B12345678901234567890123456789CD"
        if let start = bodyString.range(of: policyMarker),
           let end = bodyString.range(of: nextBoundary, range: start.upperBound..<bodyString.endIndex) {
            let policySection = bodyString[start.upperBound..<end.lowerBound]
            XCTAssertFalse(policySection.contains("Content-Type:"),
                          "文本 part 不应包含 Content-Type header")
        } else {
            XCTFail("找不到 policy part 边界")
        }
    }

    func test_generateBoundary_isValidCharsetAnd32Chars() {
        for _ in 0..<20 {
            let b = OssMultipartBodyBuilder.generateBoundary()
            XCTAssertEqual(b.count, 32)
            let valid = CharacterSet.alphanumerics
            XCTAssertTrue(b.unicodeScalars.allSatisfy { valid.contains($0) },
                         "boundary 必须 [A-Za-z0-9]（红队 #2）")
        }
    }

    func test_filenameDerivedFromObjectKey() {
        // filename 必须是 object key 的 lastPathComponent
        let out = OssMultipartBodyBuilder.build(
            credential: OssCredential.fixture(),
            objectKey: "00000000/20260626/unique-uuid.jpg",
            imageData: Data([0x00]),
            boundary: "B12345678901234567890123456789EF"
        )
        let bodyString = String(data: out.body, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("filename=\"unique-uuid.jpg\""))
    }

    // MARK: - H-2 视频路径（spec §1.7 v2 参数化改造回归）

    /// 视频上传：contentType=video/mp4 + objectAcl=private → body 必含 x-oss-object-acl part
    func test_build_video_containsAclAndVideoContentType() {
        let out = OssMultipartBodyBuilder.build(
            credential: OssCredential.fixture(),
            objectKey: "00000000/20260702/vid.mp4",
            fileData: Data([0x00, 0x01]),
            contentType: "video/mp4",
            objectAcl: "private",
            boundary: "B12345678901234567890123456789VD"
        )
        let bodyString = String(data: out.body, encoding: .utf8) ?? ""
        // acl part 必须存在（spec §1.7 hard requirement）
        XCTAssertTrue(bodyString.contains("name=\"x-oss-object-acl\""),
                      "视频 build 必须含 x-oss-object-acl part（spec §1.7）")
        XCTAssertTrue(bodyString.contains("\r\n\r\nprivate\r\n"),
                      "x-oss-object-acl 值必须 = private")
        // file part 的 Content-Type 是 video/mp4
        XCTAssertTrue(bodyString.contains("Content-Type: video/mp4"))
        XCTAssertFalse(bodyString.contains("Content-Type: image/jpeg"),
                      "视频路径不应残留 image/jpeg")
    }

    /// 视频字段顺序：x-oss-object-acl 必在 success_action_status 之后、file 之前
    func test_build_video_aclOrderBeforeFile() {
        let out = OssMultipartBodyBuilder.build(
            credential: OssCredential.fixture(),
            objectKey: "x.mp4",
            fileData: Data([0x00]),
            contentType: "video/mp4",
            objectAcl: "private",
            boundary: "B12345678901234567890123456789OR"
        )
        let bodyString = String(data: out.body, encoding: .utf8) ?? ""
        let statusIdx = bodyString.range(of: "name=\"success_action_status\"")!.lowerBound
        let aclIdx = bodyString.range(of: "name=\"x-oss-object-acl\"")!.lowerBound
        let fileIdx = bodyString.range(of: "name=\"file\"")!.lowerBound
        XCTAssertLessThan(statusIdx, aclIdx)
        XCTAssertLessThan(aclIdx, fileIdx)
    }

    /// 图片 shim（老签名 imageData:）默认 objectAcl=nil：body 不应含 x-oss-object-acl part
    /// —— 保 J 朋友圈 / 反馈 / 头像 路径行为不变（v2 red team #8）
    func test_build_imageDefaultShim_noAclPart() {
        let out = OssMultipartBodyBuilder.build(
            credential: OssCredential.fixture(),
            objectKey: "img.jpg",
            imageData: Data([0x00]),
            boundary: "B12345678901234567890123456789IM"
        )
        let bodyString = String(data: out.body, encoding: .utf8) ?? ""
        XCTAssertFalse(bodyString.contains("x-oss-object-acl"),
                      "图片默认路径不应含 acl part（保 J 朋友圈行为不变）")
        XCTAssertTrue(bodyString.contains("Content-Type: image/jpeg"))
    }
}

private extension Data {
    mutating func append(string: String) {
        if let d = string.data(using: .utf8) {
            self.append(d)
        }
    }
}
