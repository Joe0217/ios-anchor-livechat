import XCTest
import Compression

/// H 里程碑 M1-10 NIMPayloadDecoder 三态解析单测（spec §4.1）。
///
/// 覆盖：字典直传 / JSON 字符串 / JSON 数组 / Base64+gzip / Base64 无 gzip /
///       非法 base64 / 非法 JSON / nil / 空字符串 / `ext` 内 data 字段提取
final class NIMPayloadDecoderTests: XCTestCase {

    // MARK: - 1. 已是字典：直接返回

    func test_dict_passthrough() {
        let raw: [String: Any] = ["pkId": "abc", "myPkValue": 100]
        let result = NIMPayloadDecoder.unwrapDataField(raw)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["pkId"] as? String, "abc")
        XCTAssertEqual(result?["myPkValue"] as? Int, 100)
    }

    // MARK: - 2. JSON 字符串：二次 parse

    func test_jsonObjectString_parses() {
        let raw = #"{"giftId":1024,"giftName":"Rose","price":99}"#
        let result = NIMPayloadDecoder.unwrapDataField(raw)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["giftId"] as? Int, 1024)
        XCTAssertEqual(result?["giftName"] as? String, "Rose")
    }

    func test_jsonStringWithWhitespace_trimmedAndParses() {
        let raw = #"   { "pkStatus": 7 }   "#
        let result = NIMPayloadDecoder.unwrapDataField(raw)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["pkStatus"] as? Int, 7)
    }

    /// 顶层是数组时（极少数 attachType），unwrapDataField 期望 [String: Any]，
    /// 数组 JSON 不是字典 → 返回 nil。这是文档化行为，由 caller 切换专门解数组的 API。
    func test_jsonArrayString_returnsNilForDictExpectation() {
        let raw = "[1,2,3]"
        XCTAssertNil(NIMPayloadDecoder.unwrapDataField(raw))
    }

    // MARK: - 3. Base64 + gzip：派对房 1001/2049/1100-1112 必经路径

    func test_base64Gzip_roundTrip() throws {
        let dict: [String: Any] = ["seatId": 3, "userId": "test_user", "nickname": "Anchor"]
        let jsonData = try JSONSerialization.data(withJSONObject: dict)
        let gzipped = try gzip(jsonData)
        let b64 = gzipped.base64EncodedString()

        let result = NIMPayloadDecoder.unwrapDataField(b64)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["seatId"] as? Int, 3)
        XCTAssertEqual(result?["userId"] as? String, "test_user")
        XCTAssertEqual(result?["nickname"] as? String, "Anchor")
    }

    // MARK: - 4. Base64 无 gzip：caller 退化场景

    func test_base64WithoutGzip_decodesAsJson() throws {
        let dict: [String: Any] = ["key": "value"]
        let jsonData = try JSONSerialization.data(withJSONObject: dict)
        let b64 = jsonData.base64EncodedString()

        let result = NIMPayloadDecoder.unwrapDataField(b64)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["key"] as? String, "value")
    }

    // MARK: - 5. 非法 / 异常分支

    func test_invalidBase64_returnsNil() {
        // 不以 { [ 开头 → 走 Base64 分支；非法 base64 → nil
        XCTAssertNil(NIMPayloadDecoder.unwrapDataField("not_valid_base64_!!!"))
    }

    func test_invalidJsonInBase64_returnsNil() {
        let garbage = "not json".data(using: .utf8)!.base64EncodedString()
        XCTAssertNil(NIMPayloadDecoder.unwrapDataField(garbage))
    }

    func test_nil_returnsNil() {
        XCTAssertNil(NIMPayloadDecoder.unwrapDataField(nil))
    }

    func test_emptyString_returnsNil() {
        XCTAssertNil(NIMPayloadDecoder.unwrapDataField(""))
    }

    func test_intType_notDictOrString_returnsNil() {
        // 既不是 Dict 也不是 String → 返回 nil（caller 自行处理）
        XCTAssertNil(NIMPayloadDecoder.unwrapDataField(NSNumber(value: 42)))
    }

    // MARK: - 6. from(ext:) helper

    func test_extConvenience_extractsDataField() {
        let ext: [String: Any] = ["attachType": 100, "data": ["pkStatus": 9]]
        let result = NIMPayloadDecoder.unwrapDataField(from: ext)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["pkStatus"] as? Int, 9)
    }

    func test_extWithoutDataField_returnsNil() {
        let ext: [String: Any] = ["attachType": 44]
        XCTAssertNil(NIMPayloadDecoder.unwrapDataField(from: ext))
    }

    // MARK: - gzip helper（仅测试用；走标准 Compression deflate + 手工拼 gzip 头/尾）

    /// 标准 gzip 容器：10-byte 头（魔数 + flag + mtime + xflg + os） + raw deflate + 8-byte trailer（crc32 + size）
    private func gzip(_ data: Data) throws -> Data {
        // gzip 头
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        // raw deflate（zlib stream 去掉 2-byte header + 4-byte adler32 trailer）
        let deflated = try rawDeflate(data)
        output.append(deflated)

        // gzip trailer: CRC32(data) + size(data) 各 4 字节小端
        let crc = crc32(data)
        output.append(contentsOf: [
            UInt8(crc & 0xff),
            UInt8((crc >> 8) & 0xff),
            UInt8((crc >> 16) & 0xff),
            UInt8((crc >> 24) & 0xff),
        ])
        let size = UInt32(data.count)
        output.append(contentsOf: [
            UInt8(size & 0xff),
            UInt8((size >> 8) & 0xff),
            UInt8((size >> 16) & 0xff),
            UInt8((size >> 24) & 0xff),
        ])
        return output
    }

    private func rawDeflate(_ data: Data) throws -> Data {
        // 使用系统 Compression API。COMPRESSION_ZLIB 是 raw deflate（无 gzip / zlib 容器）。
        // M1-10 验证用：GzipDecompressor 内部走 zlib raw deflate；这里反向构造一样的格式。
        return try data.withUnsafeBytes { src -> Data in
            let srcBuf = src.bindMemory(to: UInt8.self)
            let dstSize = max(64, data.count * 2 + 64)
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
            defer { dst.deallocate() }
            let written = compression_encode_buffer(dst, dstSize,
                                                     srcBuf.baseAddress!, data.count,
                                                     nil, COMPRESSION_ZLIB)
            guard written > 0 else { throw NSError(domain: "gzip-test", code: -1) }
            return Data(bytes: dst, count: written)
        }
    }

    private func crc32(_ data: Data) -> UInt32 {
        // 极简 CRC32（IEEE 802.3）；测试用就够，不优化。
        let polynomial: UInt32 = 0xEDB88320
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ polynomial : crc >> 1
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

