import XCTest

/// LiveListService.decodeItems 5 路 fallback 测试（对齐 BlocklistService 同款 R-21）。
final class LiveListDecodeTests: XCTestCase {

    func test_topLevelArray_decodesCleanly() {
        let json = """
        [{"userId":"100","nickname":"Sarah","userLevel":"5","country":"USA","yxAccid":"a1"}]
        """.data(using: .utf8)!
        let items = LiveListService.decodeItems(from: json)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].userId, "100")
        XCTAssertEqual(items[0].nickname, "Sarah")
        XCTAssertEqual(items[0].userLevel, "5")
    }

    func test_userId_intIsCoercedToString() {
        // H5 接口 userId 可能下发为 Int；Decodable 应兼容
        let json = """
        [{"userId":100,"nickname":"Sarah","yxAccid":"a1"}]
        """.data(using: .utf8)!
        let items = LiveListService.decodeItems(from: json)
        XCTAssertEqual(items.first?.userId, "100")
    }

    func test_wrappedListKey_decodes() {
        let json = """
        {"list":[{"userId":"1","nickname":"A","yxAccid":"x"}]}
        """.data(using: .utf8)!
        let items = LiveListService.decodeItems(from: json)
        XCTAssertEqual(items.count, 1)
    }

    func test_wrappedRowsKey_decodes() {
        let json = """
        {"rows":[{"userId":"2","nickname":"B","yxAccid":"y"}]}
        """.data(using: .utf8)!
        let items = LiveListService.decodeItems(from: json)
        XCTAssertEqual(items.count, 1)
    }

    func test_nullLiteral_returnsEmpty() {
        let items = LiveListService.decodeItems(from: Data("null".utf8))
        XCTAssertEqual(items, [])
    }

    func test_unknownTopLevelDict_returnsEmpty() {
        let json = """
        {"weird":"shape"}
        """.data(using: .utf8)!
        XCTAssertEqual(LiveListService.decodeItems(from: json), [])
    }

    func test_garbage_returnsEmpty() {
        XCTAssertEqual(LiveListService.decodeItems(from: Data("not json".utf8)), [])
    }

    func test_vipExpire_inFuture_setsBadge() {
        let future = Int64(Date().timeIntervalSince1970 * 1000) + 86_400_000
        let json = """
        [{"userId":"1","nickname":"A","yxAccid":"x","vipExpireTime":\(future)}]
        """.data(using: .utf8)!
        let items = LiveListService.decodeItems(from: json)
        XCTAssertTrue(items[0].hasVipBadge)
    }

    func test_vipExpire_inPast_noBadge() {
        let json = """
        [{"userId":"1","nickname":"A","yxAccid":"x","vipExpireTime":1}]
        """.data(using: .utf8)!
        let items = LiveListService.decodeItems(from: json)
        XCTAssertFalse(items[0].hasVipBadge)
    }

    func test_userLevelZero_noBadge() {
        let json = """
        [{"userId":"1","nickname":"A","yxAccid":"x","userLevel":"0"}]
        """.data(using: .utf8)!
        let items = LiveListService.decodeItems(from: json)
        XCTAssertFalse(items[0].hasLevelBadge)
    }

    func test_userLevelNonZero_hasBadge() {
        let json = """
        [{"userId":"1","nickname":"A","yxAccid":"x","userLevel":"5"}]
        """.data(using: .utf8)!
        let items = LiveListService.decodeItems(from: json)
        XCTAssertTrue(items[0].hasLevelBadge)
    }

    func test_segment_keyword_mapping() {
        XCTAssertEqual(LiveListSegment.online.keyword, 1)
        XCTAssertEqual(LiveListSegment.prime.keyword, 2)
    }
}
