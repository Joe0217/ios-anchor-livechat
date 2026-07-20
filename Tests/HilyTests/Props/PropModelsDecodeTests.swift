import XCTest

/// PropModels Codable + 边界单测（spec §5.2 R13/R14/R16/R17/R31）。
///
/// 对应表：
/// - R13 expireTime 严格 H5（"-1"/-1=permanent；0/负数走 timestamp）→ test_expireTime_*
/// - R14 秒/毫秒/越界兜底 → test_expireTime_fromEpoch_*
/// - R16 records 含未知 itemType skip 而非整体 fail → test_pagedecode_skipsUnknownItemType
/// - R17 id String/Int 双兼容 → test_id_stringOrInt_bothWork
/// - R31 CodingKey alias（itemName vs name / itemImg vs imgUrl etc.）→ test_alias_*
/// - PropExpireTime.format 边界 → test_format_*
final class PropModelsDecodeTests: XCTestCase {

    // MARK: - PropExpireTime · 严格 H5 语义（R13）

    func test_expireTime_stringMinusOne_isPermanent() throws {
        let json = #""-1""#
        let t = try JSONDecoder().decode(PropExpireTime.self, from: Data(json.utf8))
        XCTAssertTrue(t.isPermanent)
    }

    func test_expireTime_intMinusOne_isPermanent() throws {
        let json = "-1"
        let t = try JSONDecoder().decode(PropExpireTime.self, from: Data(json.utf8))
        XCTAssertTrue(t.isPermanent)
    }

    /// R13 关键：Int 0 → 严格 H5 视为 timestamp（"0D:00H:00M"），非 permanent
    func test_expireTime_intZero_isTimestampNotPermanent() throws {
        let json = "0"
        let t = try JSONDecoder().decode(PropExpireTime.self, from: Data(json.utf8))
        XCTAssertFalse(t.isPermanent)
        // remaining < 0（过期）
        if case .timestamp(let epoch) = t {
            XCTAssertEqual(epoch, 0)
        } else {
            XCTFail("expected timestamp(0)")
        }
    }

    // MARK: - PropExpireTime.fromEpoch · 秒/毫秒/越界（R14）

    func test_expireTime_fromEpoch_secondsRange_treatedAsSeconds() {
        // < 10^10 视为秒（如 2050 年是 ~2.5×10^9）
        let n: Int64 = 2_500_000_000
        let t = PropExpireTime.fromEpoch(n)
        if case .timestamp(let epoch) = t {
            XCTAssertEqual(epoch, TimeInterval(n))
        } else {
            XCTFail("expected timestamp seconds")
        }
    }

    func test_expireTime_fromEpoch_millisecondsRange_dividedBy1000() {
        // 10^10 ~ 10^13 视为毫秒（如 2030 年 ~1.9×10^12 ms）
        let n: Int64 = 1_900_000_000_000
        let t = PropExpireTime.fromEpoch(n)
        if case .timestamp(let epoch) = t {
            XCTAssertEqual(epoch, TimeInterval(n) / 1000, accuracy: 0.001)
        } else {
            XCTFail("expected timestamp ms")
        }
    }

    func test_expireTime_fromEpoch_outOfRange_fallbackPermanent() {
        // > 10^13 越界（如微秒）→ 兜底 permanent（不 crash）
        let n: Int64 = 20_000_000_000_000
        XCTAssertTrue(PropExpireTime.fromEpoch(n).isPermanent)
    }

    // MARK: - PropExpireTime.format 边界

    func test_format_zero_returnsZeroString() {
        XCTAssertEqual(PropExpireTime.format(remaining: 0), "0D:00H:00M")
    }

    func test_format_negative_clampedToZero() {
        XCTAssertEqual(PropExpireTime.format(remaining: -1000), "0D:00H:00M")
    }

    func test_format_oneMinute() {
        XCTAssertEqual(PropExpireTime.format(remaining: 60), "0D:00H:01M")
    }

    func test_format_oneHourTwoMinutes() {
        XCTAssertEqual(PropExpireTime.format(remaining: 3720), "0D:01H:02M")
    }

    func test_format_twoDaysThreeHoursFourMinutes() {
        let t: TimeInterval = 2 * 86400 + 3 * 3600 + 4 * 60
        XCTAssertEqual(PropExpireTime.format(remaining: t), "2D:03H:04M")
    }

    // MARK: - PropItem.id · String/Int 双兼容（R17）

    func test_id_asInt64_decodes() throws {
        let json = """
        { "id": 12345, "itemType": 2, "itemName": "F", "itemImg": "u", "itemSmallImg": "s", "isFromBag": 1, "wearStatus": 0, "expireTime": "-1" }
        """
        let item = try JSONDecoder().decode(PropItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.id, 12345)
    }

    func test_id_asString_decodes() throws {
        let json = """
        { "id": "67890", "itemType": 2, "itemName": "F", "itemImg": "u", "itemSmallImg": "s", "isFromBag": 1, "wearStatus": 0, "expireTime": "-1" }
        """
        let item = try JSONDecoder().decode(PropItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.id, 67890)
    }

    func test_id_missing_throws() {
        let json = """
        { "itemType": 2, "itemName": "F", "itemImg": "u", "itemSmallImg": "s", "isFromBag": 1, "wearStatus": 0, "expireTime": "-1" }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(PropItem.self, from: Data(json.utf8)))
    }

    // MARK: - CodingKey alias（R31 骨架 · Step 3 真机对齐后清）

    func test_alias_itemIdInsteadOfId() throws {
        let json = """
        { "itemId": 999, "itemType": 2, "itemName": "F", "itemImg": "u", "itemSmallImg": "s", "isFromBag": 1, "wearStatus": 0, "expireTime": "-1" }
        """
        let item = try JSONDecoder().decode(PropItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.id, 999)
    }

    func test_alias_typeInsteadOfItemType() throws {
        let json = """
        { "id": 1, "type": 4, "itemName": "F", "itemImg": "u", "itemSmallImg": "s", "isFromBag": 1, "wearStatus": 0, "expireTime": "-1" }
        """
        let item = try JSONDecoder().decode(PropItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.itemType, .chatSkin)
    }

    func test_alias_imgUrlInsteadOfItemImg() throws {
        let json = """
        { "id": 1, "itemType": 2, "itemName": "F", "imgUrl": "http://a.svga", "isFromBag": 1, "wearStatus": 0, "expireTime": "-1" }
        """
        let item = try JSONDecoder().decode(PropItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.itemImg, "http://a.svga")
        // itemSmallImg 缺失 → fallback itemImg
        XCTAssertEqual(item.itemSmallImg, "http://a.svga")
    }

    // MARK: - PropItem itemType 未知 → fail-loud（R16 边界：单项）

    func test_itemType_unknownRawValue_throws() {
        let json = """
        { "id": 1, "itemType": 99, "itemName": "F", "itemImg": "u", "itemSmallImg": "s", "isFromBag": 1, "wearStatus": 0, "expireTime": "-1" }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(PropItem.self, from: Data(json.utf8)))
    }

    // MARK: - PropPage · records 混合含未知类型 → skip 而非整体 fail（R16）

    func test_page_recordsWithUnknownItemType_skipsThatOne() throws {
        let json = """
        {
          "records": [
            { "id": 1, "itemType": 2, "itemName": "OK", "itemImg": "u", "itemSmallImg": "s", "isFromBag": 1, "wearStatus": 0, "expireTime": "-1" },
            { "id": 99, "itemType": 99, "itemName": "BAD", "itemImg": "u", "itemSmallImg": "s", "isFromBag": 1, "wearStatus": 0, "expireTime": "-1" },
            { "id": 3, "itemType": 4, "itemName": "OK2", "itemImg": "u", "itemSmallImg": "s", "isFromBag": 1, "wearStatus": 0, "expireTime": "-1" }
          ],
          "totalNum": 3
        }
        """
        let page = try JSONDecoder().decode(PropPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.records.count, 2)
        XCTAssertEqual(page.records.map(\.id), [1, 3])
        XCTAssertEqual(page.totalNum, 3)
    }

    // MARK: - PropPage · totalNum alias（total / totalCount）

    func test_page_totalAliasDecodes() throws {
        let json = """
        { "list": [], "total": 5 }
        """
        let page = try JSONDecoder().decode(PropPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.totalNum, 5)
        XCTAssertEqual(page.records.count, 0)
    }

    // MARK: - PropItem.isSVGA/isMP4Resource 判断（R18 兼容 query string）

    func test_isSVGA_containsCheck_worksWithQueryString() {
        let item = PropItem(id: 1, itemType: .frame, itemName: "F",
                            itemImg: "https://cdn.com/a.svga?token=xyz",
                            isFromBag: 1, wearStatus: 0, expireTime: .permanent)
        XCTAssertTrue(item.isSVGAResource)
        XCTAssertFalse(item.isMP4Resource)
    }

    func test_isMP4_containsCheck_worksWithWebm() {
        let item = PropItem(id: 1, itemType: .vehicle, itemName: "V",
                            itemImg: "https://cdn.com/v.webm",
                            isFromBag: 1, wearStatus: 0, expireTime: .permanent)
        XCTAssertTrue(item.isMP4Resource)
        XCTAssertFalse(item.isSVGAResource)
    }

    func test_isMP4_uppercaseWorks() {
        let item = PropItem(id: 1, itemType: .vehicle, itemName: "V",
                            itemImg: "https://cdn.com/V.MP4?v=2",
                            isFromBag: 1, wearStatus: 0, expireTime: .permanent)
        XCTAssertTrue(item.isMP4Resource)
    }

    // MARK: - PropTabItemType · tabOrder 对齐 H5

    func test_tabOrder_alignsH5_AllFirst_thenFrameVehicleChatSkinCardFrame() {
        let expected: [PropTabItemType?] = [nil, .frame, .vehicle, .chatSkin, .cardFrame]
        XCTAssertEqual(PropTabItemType.tabOrder, expected)
    }

    func test_allCases_excludesEntrance() {
        let ids = PropTabItemType.allCases.map(\.rawValue).sorted()
        XCTAssertEqual(ids, [1, 2, 4, 5])
        XCTAssertFalse(PropTabItemType.allTabAllowedRawValues.contains(3))
    }
}
