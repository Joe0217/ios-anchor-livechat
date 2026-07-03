import XCTest

/// PrivateMediaDecoder + diff 算法单测（H-2 spec §1.4/§1.5/§2.2）。
final class PrivateMediaDecoderTests: XCTestCase {

    // MARK: - decode 单项字段别名映射

    func test_decode_imageWithGiftIcon_success() {
        let dict: [String: Any] = [
            "id": "server_1", "iconType": 1,
            "giftIcon": "https://oss.test/a.jpg",
            "gift": 100, "giftName": "Rose"
        ]
        let m = PrivateMediaDecoder.decode(from: dict)
        XCTAssertNotNil(m)
        XCTAssertEqual(m?.iconType, 1)
        XCTAssertEqual(m?.originalUrl, "https://oss.test/a.jpg")
        XCTAssertEqual(m?.giftId, "100")
    }

    func test_decode_videoWithVideoUrl_success() {
        let dict: [String: Any] = [
            "id": "server_2", "iconType": 2,
            "videoUrl": "https://oss.test/v.mp4",
            "gift": "200"   // String 兼容
        ]
        let m = PrivateMediaDecoder.decode(from: dict)
        XCTAssertEqual(m?.iconType, 2)
        XCTAssertEqual(m?.originalUrl, "https://oss.test/v.mp4")
        XCTAssertEqual(m?.giftId, "200", "gift 字段 String/Int 兼容")
    }

    func test_decode_iconTypeNot1or2_returnsNil() {
        let dict: [String: Any] = ["id": "x", "iconType": 3, "giftIcon": "url", "gift": 1]
        XCTAssertNil(PrivateMediaDecoder.decode(from: dict), "iconType 非 1/2 视为异常项跳过")
    }

    func test_decode_missingId_returnsNil() {
        let dict: [String: Any] = ["iconType": 1, "giftIcon": "url", "gift": 1]
        XCTAssertNil(PrivateMediaDecoder.decode(from: dict))
    }

    func test_decode_emptyUrl_returnsNil() {
        let dict: [String: Any] = ["id": "x", "iconType": 1, "giftIcon": "", "gift": 1]
        XCTAssertNil(PrivateMediaDecoder.decode(from: dict), "url 空返 nil")
    }

    func test_decode_giftIdAsBool_rejected() {
        let dict: [String: Any] = ["id": "x", "iconType": 1, "giftIcon": "url", "gift": true]
        XCTAssertNil(PrivateMediaDecoder.decode(from: dict), "Bool 桥接排除")
    }

    func test_decode_missingGift_returnsNil() {
        let dict: [String: Any] = ["id": "x", "iconType": 1, "giftIcon": "url"]
        XCTAssertNil(PrivateMediaDecoder.decode(from: dict))
    }

    // MARK: - decodeList 边界

    func test_decodeList_nullLiteral_empty() {
        XCTAssertEqual(PrivateMediaDecoder.decodeList(from: Data("null".utf8)).count, 0)
    }

    func test_decodeList_emptyArray() {
        XCTAssertEqual(PrivateMediaDecoder.decodeList(from: Data("[]".utf8)).count, 0)
    }

    func test_decodeList_mixedValidAndInvalid_skipsInvalid() {
        let json = """
        [
          {"id":"1","iconType":1,"giftIcon":"u1","gift":100},
          {"id":"2","iconType":3,"giftIcon":"u2","gift":200},
          {"id":"3","iconType":2,"videoUrl":"v3","gift":"300"}
        ]
        """
        let list = PrivateMediaDecoder.decodeList(from: Data(json.utf8))
        XCTAssertEqual(list.count, 2, "iconType=3 项被跳过")
        XCTAssertEqual(list[0].id, "1")
        XCTAssertEqual(list[1].id, "3")
    }

    func test_decodeList_garbage_returnsEmpty() {
        XCTAssertEqual(PrivateMediaDecoder.decodeList(from: Data("not-json".utf8)).count, 0)
    }

    // MARK: - Diff 算法（spec §1.5 v2）

    func test_diff_pureAdd_ops() {
        let original: [PrivateMedia] = []
        let current: [PrivateMedia] = [
            PrivateMedia(id: "local_uuid1", iconType: 1, originalUrl: "u1",
                         signedUrl: nil, signedAt: nil,
                         giftId: "100", giftName: nil, giftPrice: nil)
        ]
        let ops = PrivateMediaDecoder.computeDiff(original: original, current: current)
        XCTAssertEqual(ops.count, 1)
        XCTAssertNil(ops.first?.id, "新增项不带 id")
        XCTAssertEqual(ops.first?.picList, "u1")
        XCTAssertNil(ops.first?.removePrivate)
    }

    func test_diff_pureDelete_ops() {
        let original: [PrivateMedia] = [.fixture(id: "server_1", iconType: 1)]
        let current: [PrivateMedia] = []
        let ops = PrivateMediaDecoder.computeDiff(original: original, current: current)
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops.first?.id, "server_1")
        XCTAssertEqual(ops.first?.removePrivate, true)
    }

    func test_diff_unchanged_hasIdNoRemove() {
        let orig: [PrivateMedia] = [.fixture(id: "server_1", iconType: 1)]
        let curr: [PrivateMedia] = [.fixture(id: "server_1", iconType: 1)]
        let ops = PrivateMediaDecoder.computeDiff(original: orig, current: curr)
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops.first?.id, "server_1")
        XCTAssertNil(ops.first?.removePrivate, "未改动项 removePrivate=nil")
    }

    func test_diff_deleteAndReuploadSameUrl_treatedAsNewNotUnchanged() {
        // v2 red team #4 修 H5 bug：先删后传同 url 不应误判为"未改动"
        let orig: [PrivateMedia] = [.fixture(id: "server_1", iconType: 1, originalUrl: "https://oss.test/a.jpg")]
        // 用户先删 → current 移除 server_1；重新上传同 url → 加 local_ 项
        let curr: [PrivateMedia] = [
            PrivateMedia(id: "local_new", iconType: 1, originalUrl: "https://oss.test/a.jpg",
                         signedUrl: nil, signedAt: nil,
                         giftId: "100", giftName: nil, giftPrice: nil)
        ]
        let ops = PrivateMediaDecoder.computeDiff(original: orig, current: curr)
        XCTAssertEqual(ops.count, 2, "1 删除 + 1 新增（非误判为未改动）")
        XCTAssertEqual(ops.filter { $0.removePrivate == true }.count, 1)
        XCTAssertEqual(ops.filter { $0.id == nil }.count, 1, "新增项无 id")
    }

    func test_diff_mixedThreeStates() {
        // 复杂：保留 A + 删除 B + 新增 C
        let orig: [PrivateMedia] = [
            .fixture(id: "A", iconType: 1),
            .fixture(id: "B", iconType: 1),
        ]
        let curr: [PrivateMedia] = [
            .fixture(id: "A", iconType: 1),
            PrivateMedia(id: "local_C", iconType: 1, originalUrl: "u_c",
                         signedUrl: nil, signedAt: nil,
                         giftId: "300", giftName: nil, giftPrice: nil),
        ]
        let ops = PrivateMediaDecoder.computeDiff(original: orig, current: curr)
        XCTAssertEqual(ops.count, 3)
        // A 未改动
        XCTAssertEqual(ops.first(where: { $0.id == "A" })?.removePrivate, nil)
        // B 删除
        XCTAssertEqual(ops.first(where: { $0.id == "B" })?.removePrivate, true)
        // C 新增
        XCTAssertNil(ops.first(where: { $0.picList == "u_c" })?.id)
    }

    func test_diff_videoOp_usesVideoUrlField() {
        let orig: [PrivateMedia] = []
        let curr: [PrivateMedia] = [
            PrivateMedia(id: "local_v", iconType: 2, originalUrl: "https://oss.test/v.mp4",
                         signedUrl: nil, signedAt: nil,
                         giftId: "200", giftName: nil, giftPrice: nil)
        ]
        let ops = PrivateMediaDecoder.computeDiff(original: orig, current: curr)
        XCTAssertEqual(ops.count, 1)
        XCTAssertNil(ops.first?.picList, "视频用 videoUrl 字段")
        XCTAssertEqual(ops.first?.videoUrl, "https://oss.test/v.mp4")
        XCTAssertEqual(ops.first?.iconType, 2)
    }

    // MARK: - encode 输出契约（step 3 反悔 #1：id 保 Number 类型）

    /// H5 送 `id: originalItem.id`（Number）；iOS decode 为 String 后 encode 时须转回 Int64。
    /// 否则 server 按 Number 主键匹配 → String 无法命中 → 删除操作静默忽略。
    func test_encode_deleteOp_idOutputAsNumber() throws {
        let orig: [PrivateMedia] = [
            PrivateMedia(id: "10086", iconType: 1,
                         originalUrl: "https://oss.test/a.jpg",
                         signedUrl: nil, signedAt: nil,
                         giftId: "100", giftName: "Rose", giftPrice: 100)
        ]
        let ops = PrivateMediaDecoder.computeDiff(original: orig, current: [])
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops.first?.removePrivate, true)

        // encode → JSON 应含 `"id":10086`（数字），非 `"id":"10086"`（字符串）
        let data = try JSONEncoder().encode(ops)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"id\":10086"), "id 必须以 Number 形式输出。actual=\(json)")
        XCTAssertFalse(json.contains("\"id\":\"10086\""), "禁止以 String 形式输出 id")
    }

    /// 新增项 id=nil → encode 时不输出 id 字段
    func test_encode_newOp_omitsIdField() throws {
        let curr: [PrivateMedia] = [
            PrivateMedia(id: "local_x", iconType: 1, originalUrl: "u",
                         signedUrl: nil, signedAt: nil, giftId: "10", giftName: nil, giftPrice: nil)
        ]
        let ops = PrivateMediaDecoder.computeDiff(original: [], current: curr)
        let data = try JSONEncoder().encode(ops)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"id\""), "新增项不应带 id 字段。actual=\(json)")
    }

    /// 非数字 id（如未来 uuid 类）→ 回落 String 输出
    func test_encode_nonNumericId_fallsBackToString() throws {
        let orig: [PrivateMedia] = [
            PrivateMedia(id: "uuid-xyz-9f", iconType: 1, originalUrl: "u",
                         signedUrl: nil, signedAt: nil, giftId: "10", giftName: nil, giftPrice: nil)
        ]
        let ops = PrivateMediaDecoder.computeDiff(original: orig, current: [])
        let data = try JSONEncoder().encode(ops)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"id\":\"uuid-xyz-9f\""), "非数字 id 回落 String。actual=\(json)")
    }
}
