import Foundation

/// 拦截 URLSession 网络请求的 mock URLProtocol，单测专用。
///
/// 用法：
/// ```
/// MockURLProtocol.handler = { request in
///     let body = Data("{\"code\":\"0000\",\"message\":\"\",\"result\":null}".utf8)
///     return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
/// }
/// let cfg = URLSessionConfiguration.ephemeral
/// cfg.protocolClasses = [MockURLProtocol.self]
/// let client = APIClient(session: URLSession(configuration: cfg))
/// ```
///
/// 注意：通过 `protocolClasses` 注入到 ephemeral config，不污染全局；测试间互不影响。
final class MockURLProtocol: URLProtocol {

    /// 测试用 handler：拿到 request，返回 (response, body)；抛错则触发 didFail。
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// 测试可读：上一次被拦截的 request（含 method / url / headers / body）。
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func reset() {
        handler = nil
        lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // URLProtocol 取 httpBody 时 httpBodyStream 会被消费——这里直接 copy 出来供测试读取
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            captured.httpBody = MockURLProtocol.readAll(stream)
        }
        MockURLProtocol.lastRequest = captured

        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: -1, userInfo: [NSLocalizedDescriptionKey: "handler 未设置"]))
            return
        }

        do {
            let (response, data) = try handler(captured)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
