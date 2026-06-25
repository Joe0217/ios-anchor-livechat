import XCTest

/// I-1 黑名单 decode 边界单测（spec §4.1 5 路 fallback + §4.2 BlocklistItem 严格契约）。
///
/// 覆盖 spec §5 R-9 / R-13 / R-21 / R-14（含同 id 不去重）+ CodingKey 别名生效反向证伪
/// （trial #1 在 step 3 真集成才挖出 `MomentPost.likeCount` 别名缺失 bug，spec §10.3 推后此教训）。
final class BlocklistDecodeTests: XCTestCase {

    // MARK: - Fallback 路径 1：result=null 字面量（spec R-21）

    func test_decodeItems_fromNullLiteral_returnsEmpty() {
        let data = Data("null".utf8)
        let r = BlocklistService.decodeItems(from: data)
        XCTAssertEqual(r.count, 0)
    }

    // MARK: - Fallback 路径 2：顶层数组（H5 标准）

    func test_decodeItems_fromTopLevelArray_decodesItems() {
        let json = """
        [
          {"userId":"100","nickname":"Alice","yxAccid":"yx_100","createTime":1716595200000},
          {"userId":"101","nickname":"Bob","yxAccid":"yx_101","createTime":1716595300000}
        ]
        """
        let r = BlocklistService.decodeItems(from: Data(json.utf8))
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].userId, "100")
        XCTAssertEqual(r[0].nickname, "Alice")
        XCTAssertEqual(r[0].createTimeMs, 1_716_595_200_000)
    }

    func test_decodeItems_fromEmptyArray_returnsEmpty() {
        let r = BlocklistService.decodeItems(from: Data("[]".utf8))
        XCTAssertEqual(r.count, 0)
    }

    // MARK: - Fallback 路径 3：wrapped 字典（list / rows / data / items）

    func test_decodeItems_fromWrappedListKey_extractsList() {
        let json = """
        {"list":[{"userId":"1","nickname":"A","yxAccid":"yx_1"}]}
        """
        let r = BlocklistService.decodeItems(from: Data(json.utf8))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].userId, "1")
    }

    func test_decodeItems_fromWrappedRowsKey_extractsRows() {
        let json = """
        {"rows":[{"userId":"2","nickname":"B","yxAccid":"yx_2"}]}
        """
        let r = BlocklistService.decodeItems(from: Data(json.utf8))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].userId, "2")
    }

    // MARK: - Fallback 路径 4：顶层字典但无 list/rows/data/items → 空 + warn

    func test_decodeItems_fromDictWithoutKnownKeys_returnsEmpty() {
        let json = """
        {"foo":"bar","total":0}
        """
        let r = BlocklistService.decodeItems(from: Data(json.utf8))
        XCTAssertEqual(r.count, 0, "未知字典形态 → 空数组（让 step 3 反悔暴露）")
    }

    // MARK: - Fallback 路径 5：无法解析

    func test_decodeItems_fromGarbage_returnsEmpty() {
        let data = Data("not-json-at-all".utf8)
        let r = BlocklistService.decodeItems(from: data)
        XCTAssertEqual(r.count, 0)
    }

    // MARK: - R-9 userId 严格 String（fail-loud）

    func test_decodeItems_userIdAsInt_failLoud_returnsEmpty() {
        // 接口契约偏移：userId 返 number 而非 string；BlocklistItem 严格 String → decode 抛
        // typeMismatch → fallback 路径 2 失败，路径 3 也失败（顶层是数组而非字典），路径 5 兜底空
        let json = """
        [{"userId":100,"nickname":"Alice","yxAccid":"yx_100"}]
        """
        let r = BlocklistService.decodeItems(from: Data(json.utf8))
        XCTAssertEqual(r.count, 0, "userId 类型偏移应 fail-loud 而非静默兼容（spec §1.3 表 #2）")
    }

    // MARK: - 必填字段缺失

    func test_decodeItems_missingRequiredFields_failsItem() {
        // userId 缺失 → 整个数组 decode 失败 → 路径 2/3 都失败 → 空数组
        let json = """
        [{"nickname":"NoUserId","yxAccid":"yx_x"}]
        """
        let r = BlocklistService.decodeItems(from: Data(json.utf8))
        XCTAssertEqual(r.count, 0)
    }

    // MARK: - Optional 字段缺失 / 0 值（spec R-11/R-12/R-13）

    func test_decodeItems_optionalFieldsAbsent_decodesWithNil() {
        let json = """
        [{"userId":"100","nickname":"Alice","yxAccid":"yx_100"}]
        """
        let r = BlocklistService.decodeItems(from: Data(json.utf8))
        XCTAssertEqual(r.count, 1)
        XCTAssertNil(r[0].icon)
        XCTAssertNil(r[0].countryId)
        XCTAssertNil(r[0].age)
        XCTAssertNil(r[0].createTimeMs)
        XCTAssertNil(r[0].createdAt)
    }

    func test_createdAt_zeroCreateTime_returnsNil() {
        let item = BlocklistItem(
            userId: "1", nickname: "A", icon: nil, countryId: nil, age: nil,
            yxAccid: "yx", gender: nil, userType: nil, createTimeMs: 0
        )
        XCTAssertNil(item.createdAt, "createTimeMs=0 视为无数据（spec R-13）")
    }

    func test_createdAt_negativeCreateTime_returnsNil() {
        let item = BlocklistItem(
            userId: "1", nickname: "A", icon: nil, countryId: nil, age: nil,
            yxAccid: "yx", gender: nil, userType: nil, createTimeMs: -1
        )
        XCTAssertNil(item.createdAt, "负值视为无数据")
    }

    // MARK: - CodingKey 别名生效反向证伪（trial #1 教训）

    func test_codingKeys_createTimeAliasIsActive() {
        // 接口字段名 `createTime`，iOS 字段名 `createTimeMs` —— 必须靠 CodingKey 别名映射
        let json = """
        [{"userId":"1","nickname":"A","yxAccid":"yx","createTime":1234567890000}]
        """
        let r = BlocklistService.decodeItems(from: Data(json.utf8))
        XCTAssertEqual(r.first?.createTimeMs, 1_234_567_890_000,
            "createTime → createTimeMs 别名必须生效；trial #1 在 step 3 才挖出类似 likeCount 别名 bug")
    }

    // MARK: - R-14 同 id 出现两次不去重（fail-loud）

    func test_decodeItems_duplicateIds_keptAsIs() {
        let json = """
        [
          {"userId":"1","nickname":"A","yxAccid":"yx_1"},
          {"userId":"1","nickname":"A2","yxAccid":"yx_1"}
        ]
        """
        let r = BlocklistService.decodeItems(from: Data(json.utf8))
        XCTAssertEqual(r.count, 2, "Service 层不去重；接口分页重叠 bug 由 ForEach duplicate id 警告暴露")
    }

    // MARK: - status 字段（H5 永远 null）不影响解码

    func test_decodeItems_statusFieldAlwaysNull_ignored() {
        let json = """
        [{"userId":"1","nickname":"A","yxAccid":"yx_1","status":null,"countryId":"US","age":24}]
        """
        let r = BlocklistService.decodeItems(from: Data(json.utf8))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].countryId, "US")
        XCTAssertEqual(r[0].age, 24)
    }
}
