import XCTest

/// Step 1c · Batch 6 新增字段 decode 边界单测。
/// 覆盖：
/// - `AnchorMediaItem.fromPrivateMedia` 透传 `giftPrice`
/// - `MessageBoxRecordItem` decode（id String/Int 双兼容 + 缺字段兜底）
/// - `StationMail` 扩展字段（mailContent / status / expiryDate）
///
/// 遵循 [.claude/rules/ios-decode-userid-compat.md](../../../.claude/rules/ios-decode-userid-compat.md)：
/// id/status 字段服务端可能返 String/Int 混发，全部走双兼容 decode。
final class Batch6ModelsDecodeTests: XCTestCase {

    // MARK: - AnchorMediaItem.fromPrivateMedia (Batch 4)

    /// Batch 4：私密相册 giftPrice 透传，图片场景 kind=.image
    func testFromPrivateMedia_Image_PropagatesGiftPrice() {
        let p = PrivateMedia(
            id: "p1", iconType: 1,
            originalUrl: "https://cdn.example.com/img.jpg",
            signedUrl: nil, signedAt: nil,
            giftId: "g1", giftName: "Rose", giftPrice: 199
        )
        let item = AnchorMediaItem.fromPrivateMedia(p)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.kind, .image)
        XCTAssertEqual(item?.giftPrice, 199)
        XCTAssertNil(item?.coverUrl)   // 私密相册无独立 coverUrl
    }

    /// 视频场景 kind=.video + giftPrice 透传
    func testFromPrivateMedia_Video_PropagatesGiftPrice() {
        let p = PrivateMedia(
            id: "p2", iconType: 2,
            originalUrl: "https://cdn.example.com/v.mp4",
            signedUrl: nil, signedAt: nil,
            giftId: "g2", giftName: nil, giftPrice: 500
        )
        let item = AnchorMediaItem.fromPrivateMedia(p)
        XCTAssertEqual(item?.kind, .video)
        XCTAssertEqual(item?.giftPrice, 500)
    }

    /// giftPrice=nil 时 AnchorMediaItem.giftPrice 也应 nil（不 default 0）
    func testFromPrivateMedia_NilGiftPrice_KeepsNil() {
        let p = PrivateMedia(
            id: "p3", iconType: 1,
            originalUrl: "https://cdn.example.com/img.jpg",
            signedUrl: nil, signedAt: nil,
            giftId: "g3", giftName: nil, giftPrice: nil
        )
        let item = AnchorMediaItem.fromPrivateMedia(p)
        XCTAssertNil(item?.giftPrice)
    }

    /// 非法 URL → return nil（不 crash）
    func testFromPrivateMedia_InvalidURL_ReturnsNil() {
        let p = PrivateMedia(
            id: "p4", iconType: 1,
            originalUrl: "",   // 空 URL string
            signedUrl: nil, signedAt: nil,
            giftId: "g4", giftName: nil, giftPrice: 100
        )
        let item = AnchorMediaItem.fromPrivateMedia(p)
        XCTAssertNil(item)
    }

    // MARK: - MessageBoxRecordItem decode（Batch 6.1.2）

    /// 全字段齐备（id String / point Int / diamond Int / createTime Int64）
    func testMessageBoxRecordItem_Decode_FullFields() throws {
        let json = """
        {"id":"r1","point":30,"diamond":100,"createTime":1720000000000}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(MessageBoxRecordItem.self, from: json)
        XCTAssertEqual(item.id, "r1")
        XCTAssertEqual(item.point, 30)
        XCTAssertEqual(item.diamond, 100)
        XCTAssertEqual(item.createTime, 1_720_000_000_000)
    }

    /// id 为 Int → 收成 String（rule ios-decode-userid-compat）
    func testMessageBoxRecordItem_Decode_IdAsInt_CoerceToString() throws {
        let json = """
        {"id":12345,"point":40,"diamond":100,"createTime":1720000000000}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(MessageBoxRecordItem.self, from: json)
        XCTAssertEqual(item.id, "12345")
    }

    /// 缺字段：point/diamond/createTime 缺失 → 兜底 0（不 throw）
    func testMessageBoxRecordItem_Decode_MissingFields_UsesZeroFallback() throws {
        let json = """
        {"id":"r2"}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(MessageBoxRecordItem.self, from: json)
        XCTAssertEqual(item.id, "r2")
        XCTAssertEqual(item.point, 0)
        XCTAssertEqual(item.diamond, 0)
        XCTAssertEqual(item.createTime, 0)
    }

    /// 完全缺 id 也不 throw（生成 UUID 兜底）—— 现实中不太发生但需要保鲁棒
    func testMessageBoxRecordItem_Decode_MissingId_GeneratesUUID() throws {
        let json = """
        {"point":10,"diamond":50}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(MessageBoxRecordItem.self, from: json)
        XCTAssertFalse(item.id.isEmpty)
        XCTAssertEqual(item.point, 10)
    }

    // MARK: - StationMail decode（Batch 3.8 扩展字段）

    /// 全字段齐备
    func testStationMail_Decode_FullFields() throws {
        let json = """
        {
          "id":"m1",
          "mailTitle":"Welcome",
          "effectiveDate":"2026-01-01",
          "mailContent":"<p>Hello</p>",
          "status":0,
          "expiryDate":"2026-12-31"
        }
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(StationMail.self, from: json)
        XCTAssertEqual(m.id, "m1")
        XCTAssertEqual(m.mailTitle, "Welcome")
        XCTAssertEqual(m.mailContent, "<p>Hello</p>")
        XCTAssertEqual(m.status, 0)
        XCTAssertEqual(m.expiryDate, "2026-12-31")
    }

    /// status 返 String → decode 兼容
    func testStationMail_Decode_StatusAsString() throws {
        let json = """
        {"id":"m2","mailTitle":"T","effectiveDate":"","mailContent":"","status":"1","expiryDate":""}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(StationMail.self, from: json)
        XCTAssertEqual(m.status, 1)
    }

    /// 新字段全缺 → 兜底 ""/0（rule async-state-fallback 应用）
    func testStationMail_Decode_ExtendedFieldsMissing_Fallback() throws {
        let json = """
        {"id":"m3","mailTitle":"OnlyTitle","effectiveDate":"2026-01-01"}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(StationMail.self, from: json)
        XCTAssertEqual(m.mailContent, "")
        XCTAssertEqual(m.status, 0)
        XCTAssertEqual(m.expiryDate, "")
    }

    /// id 为 Int → 收成 String（同 ios-decode-userid-compat）
    func testStationMail_Decode_IdAsInt() throws {
        let json = """
        {"id":42,"mailTitle":"T","effectiveDate":""}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(StationMail.self, from: json)
        XCTAssertEqual(m.id, "42")
    }
}
