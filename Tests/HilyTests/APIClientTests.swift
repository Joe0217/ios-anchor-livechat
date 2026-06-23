import XCTest

/// APIClient 公共头 + 请求体加密 + 响应 envelope 解析 + 错误码分流的特征测试。
/// 通过 URLProtocolMock 拦截 URLSession，不依赖任何真实网络。
final class APIClientTests: XCTestCase {

    private var client: APIClient!

    override func setUp() {
        super.setUp()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        client = APIClient(session: URLSession(configuration: cfg))
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        client = nil
        super.tearDown()
    }

    // MARK: - \u{8bf7}\u{6c42}\u{4f53}\u{52a0}\u{5bc6}：JSON \u{2192} AES-CBC \u{2192} Base64

    func testPost_bodyIsAESBase64EncryptedJSON() async throws {
        // \u{670d}\u{52a1}\u{7aef}\u{56de}\u{4e2a}\u{6700}\u{7b80}\u{6210}\u{529f}\u{5305}\u{8df3}\u{8fc7} envelope \u{6b65}
        MockURLProtocol.handler = { req in
            (Self.ok200(req.url!), Self.envelope(code: "0000", resultHex: nil))
        }

        let body: [String: Any] = ["account": "test@example.com", "password": "abc"]
        _ = try await client.post("/api/login/v4/login", body: body)

        // \u{9a8c}\u{8bc1}：\u{6293}\u{5230}\u{7684} httpBody \u{80fd}\u{7528} CryptoUtil \u{53cd}\u{5411}\u{89e3}\u{56de}\u{539f} JSON
        guard let captured = MockURLProtocol.lastRequest,
              let httpBody = captured.httpBody,
              let base64 = String(data: httpBody, encoding: .utf8) else {
            return XCTFail("\u{6293}\u{4e0d}\u{5230}\u{8bf7}\u{6c42}\u{4f53}")
        }
        // base64 \u{2192} Data \u{2192} hex \u{2192} aesDecryptFromHex
        guard let cipherData = Data(base64Encoded: base64) else {
            return XCTFail("\u{8bf7}\u{6c42}\u{4f53}\u{4e0d}\u{662f}\u{5408}\u{6cd5} base64")
        }
        let hex = cipherData.map { String(format: "%02x", $0) }.joined()
        guard let decrypted = CryptoUtil.aesDecryptFromHex(hex) else {
            return XCTFail("\u{89e3}\u{5bc6}\u{5931}\u{8d25}")
        }
        let json = try JSONSerialization.jsonObject(with: Data(decrypted.utf8)) as? [String: Any]
        XCTAssertEqual(json?["account"] as? String, "test@example.com")
        XCTAssertEqual(json?["password"] as? String, "abc")
    }

    func testPost_withNilBody_sendsNoHTTPBody() async throws {
        MockURLProtocol.handler = { req in
            (Self.ok200(req.url!), Self.envelope(code: "0000", resultHex: nil))
        }
        _ = try await client.post("/api/some/endpoint", body: nil)
        XCTAssertNil(MockURLProtocol.lastRequest?.httpBody, "body=nil \u{65f6}\u{4e0d}\u{5e94}\u{6709} httpBody")
    }

    // MARK: - \u{516c}\u{5171}\u{8bf7}\u{6c42}\u{5934}（\u{5bf9}\u{9f50} H5 \u{8bf7}\u{6c42}\u{62e6}\u{622a}\u{5668}）

    func testPost_attachesCommonHeaders() async throws {
        MockURLProtocol.handler = { req in
            (Self.ok200(req.url!), Self.envelope(code: "0000", resultHex: nil))
        }
        _ = try await client.post("/api/x", token: "test-token-123")

        let headers = MockURLProtocol.lastRequest?.allHTTPHeaderFields ?? [:]
        XCTAssertEqual(headers["appid"], AppConfig.appId)
        XCTAssertEqual(headers["Ocp-Apim-Subscription-Key"], AppConfig.ocpApimKey)
        XCTAssertEqual(headers["osType"], "iOS")
        XCTAssertEqual(headers["deviceType"], "iPhone")
        XCTAssertEqual(headers["loginToken"], "test-token-123")
        XCTAssertEqual(headers["anchorToken"], "test-token-123", "anchorToken \u{4e0e} loginToken \u{503c}\u{5b8c}\u{5168}\u{4e00}\u{81f4}（H5 \u{884c}\u{4e3a}）")
        XCTAssertEqual(headers["Content-Type"], "application/json;charset=UTF-8")
        XCTAssertFalse(headers["deviceId"]?.isEmpty ?? true)
    }

    // MARK: - \u{54cd}\u{5e94} envelope \u{89e3}\u{6790}

    func testPost_successWithEncryptedResult_returnsDecryptedJSON() async throws {
        let payload = "{\"uid\":\"42\",\"name\":\"alice\"}"
        let resultHex = Self.aesEncryptToHex(payload)!
        MockURLProtocol.handler = { req in
            (Self.ok200(req.url!), Self.envelope(code: "0000", resultHex: resultHex))
        }

        let data = try await client.post("/api/x")
        let str = String(data: data, encoding: .utf8)
        XCTAssertEqual(str, payload, "result Hex \u{5e94}\u{89e3}\u{5bc6}\u{56de}\u{539f} JSON \u{5b57}\u{8282}\u{6d41}")
    }

    func testPost_successWithNullResult_returnsLiteralNullData() async throws {
        // result=null（\u{4e0d}\u{52a0}\u{5bc6}）\u{2192} \u{8fd4}\u{56de} "null" \u{5b57}\u{8282}\u{4e32}（\u{4e0a}\u{6e38} Codable \u{53ef}\u{89e3}\u{4e3a} nil）
        MockURLProtocol.handler = { req in
            (Self.ok200(req.url!), Self.envelope(code: "0000", resultHex: nil))
        }
        let data = try await client.post("/api/heartbeat")
        XCTAssertEqual(String(data: data, encoding: .utf8), "null")
    }

    func testPost_successWithDictResultNotEncrypted_returnsJSONOfDict() async throws {
        // \u{6709}\u{4e9b}\u{63a5}\u{53e3} result \u{76f4}\u{63a5}\u{8fd4}\u{56de}\u{660e}\u{6587}\u{5b57}\u{5178}（\u{53ea}\u{6709} JSON \u{9876}\u{5c42}\u{5bf9}\u{8c61}\u{624d}\u{56de}\u{4f20}，\u{907f}\u{514d} OC \u{5f02}\u{5e38}）
        let env = Data("{\"code\":\"0000\",\"message\":\"\",\"result\":{\"k\":\"v\"}}".utf8)
        MockURLProtocol.handler = { req in (Self.ok200(req.url!), env) }
        let data = try await client.post("/api/x")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(obj?["k"], "v")
    }

    // MARK: - \u{9519}\u{8bef}\u{7801}\u{5206}\u{6d41}（\u{4e1a}\u{52a1} code \u{975e} 0000）

    func testPost_errorCode1004_throwsAPIErrorWithCodeAndMessage() async {
        let env = Data("{\"code\":\"1004\",\"message\":\"\u{6324}\u{4e0b}\u{7ebf}\",\"result\":null}".utf8)
        MockURLProtocol.handler = { req in (Self.ok200(req.url!), env) }
        do {
            _ = try await client.post("/api/x")
            XCTFail("\u{5e94}\u{629b}\u{9519}")
        } catch let err as APIError {
            XCTAssertEqual(err.code, "1004")
            XCTAssertEqual(err.message, "\u{6324}\u{4e0b}\u{7ebf}")
        } catch {
            XCTFail("\u{671f}\u{671b} APIError，\u{5f97}\u{5230}: \(error)")
        }
    }

    func testPost_errorCode1005_throwsAPIError() async {
        let env = Data("{\"code\":\"1005\",\"message\":\"token\u{5931}\u{6548}\",\"result\":null}".utf8)
        MockURLProtocol.handler = { req in (Self.ok200(req.url!), env) }
        do {
            _ = try await client.post("/api/x")
            XCTFail("\u{5e94}\u{629b}\u{9519}")
        } catch let err as APIError {
            XCTAssertEqual(err.code, "1005")
        } catch {
            XCTFail("expected APIError")
        }
    }

    func testPost_errorCodeWithEmptyMessage_fillsDefaultMessage() async {
        let env = Data("{\"code\":\"1992\",\"message\":\"\",\"result\":null}".utf8)
        MockURLProtocol.handler = { req in (Self.ok200(req.url!), env) }
        do {
            _ = try await client.post("/api/x")
            XCTFail("\u{5e94}\u{629b}\u{9519}")
        } catch let err as APIError {
            XCTAssertEqual(err.code, "1992")
            XCTAssertEqual(err.message, "\u{8bf7}\u{6c42}\u{5931}\u{8d25}(1992)", "message \u{4e3a}\u{7a7a}\u{65f6}\u{5e94}\u{586b}\u{9ed8}\u{8ba4}\u{6587}\u{6848}\u{542b}\u{7801}")
        } catch {
            XCTFail("expected APIError")
        }
    }

    // MARK: - \u{54cd}\u{5e94}\u{683c}\u{5f0f}\u{5f02}\u{5e38}

    func testPost_malformedResponseJSON_throwsAPIErrorMinusOne() async {
        let bad = Data("not a json".utf8)
        MockURLProtocol.handler = { req in (Self.ok200(req.url!), bad) }
        do {
            _ = try await client.post("/api/x")
            XCTFail("\u{5e94}\u{629b}\u{9519}")
        } catch let err as APIError {
            XCTAssertEqual(err.code, "-1")
            XCTAssertEqual(err.message, "\u{54cd}\u{5e94}\u{89e3}\u{6790}\u{5931}\u{8d25}")
        } catch {
            XCTFail("expected APIError")
        }
    }

    func testPost_emptyResponseBody_throwsAPIErrorMinusOne() async {
        MockURLProtocol.handler = { req in (Self.ok200(req.url!), Data()) }
        do {
            _ = try await client.post("/api/x")
            XCTFail("\u{5e94}\u{629b}\u{9519}")
        } catch let err as APIError {
            XCTAssertEqual(err.code, "-1")
        } catch {
            XCTFail("expected APIError")
        }
    }

    // MARK: - Test helpers

    private static func ok200(_ url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    /// \u{8d34}\u{8fd1} H5 \u{670d}\u{52a1}\u{7aef}\u{8fd4}\u{56de}\u{683c}\u{5f0f}：{code, message, result}。
    /// resultHex=nil \u{2192} "result":null；\u{6709}\u{503c} \u{2192} "result":"<hex>"
    private static func envelope(code: String, message: String = "", resultHex: String?) -> Data {
        let resultPart: String
        if let h = resultHex { resultPart = "\"\(h)\"" } else { resultPart = "null" }
        return Data("{\"code\":\"\(code)\",\"message\":\"\(message)\",\"result\":\(resultPart)}".utf8)
    }

    /// \u{52a0}\u{5bc6}\u{660e}\u{6587}\u{6210} Hex（\u{670d}\u{52a1}\u{7aef}\u{8fd4}\u{56de} result \u{683c}\u{5f0f}）。
    /// \u{8d70}\u{4e0e}\u{4ea7}\u{54c1}\u{4ee3}\u{7801}\u{4e00}\u{6837}\u{7684} CryptoUtil：\u{52a0}\u{5bc6}\u{5f97} base64 \u{518d}\u{8f6c} hex。
    private static func aesEncryptToHex(_ plain: String) -> String? {
        guard let base64 = CryptoUtil.aesEncryptToBase64(plain),
              let data = Data(base64Encoded: base64) else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}
