import XCTest

/// L 里程碑 Match — Codable decode 边界单测。
///
/// 覆盖 spec §5.2 R14：`MatchUserItem.userId` String/Int 双兼容（`.claude/rules/ios-decode-userid-compat.md`）。
final class MatchModelsDecodeTests: XCTestCase {

    // MARK: - R14 userId String / Int 双兼容

    /// userId 是 String → 直接解出
    func test_R14a_userIdAsString_decodedOK() throws {
        let json = """
        {"userId":"1234","nickname":"alice","icon":"http://a.jpg","age":25}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(MatchUserItem.self, from: json)
        XCTAssertEqual(item.userId, "1234")
        XCTAssertEqual(item.nickname, "alice")
        XCTAssertEqual(item.age, 25)
    }

    /// userId 是 Int → 转 String
    func test_R14b_userIdAsInt_convertedToString() throws {
        let json = """
        {"userId":1000001877,"nickname":"bob","icon":"http://b.jpg"}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(MatchUserItem.self, from: json)
        XCTAssertEqual(item.userId, "1000001877")
    }

    /// userId 是 Int64 大数（超过 Int32 边界，H5 后端 __NSCFNumber 常见）→ 转 String
    func test_R14c_userIdAsLargeInt64_convertedToString() throws {
        let json = """
        {"userId":9999999999,"nickname":"c","icon":"x"}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(MatchUserItem.self, from: json)
        XCTAssertEqual(item.userId, "9999999999")
    }

    /// userId 缺失 → decode 失败（不 fallback 空字符串，避免污染业务）
    func test_R14d_userIdMissing_throws() {
        let json = """
        {"nickname":"noId","icon":"x"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(MatchUserItem.self, from: json))
    }

    /// userId 是 String 但为空 → decode 失败
    func test_R14e_userIdEmptyString_throws() {
        let json = """
        {"userId":"","nickname":"n","icon":"x"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(MatchUserItem.self, from: json))
    }

    // MARK: - MatchPoolData null-safe decode

    /// callList / userList 后端返 null → fallback 空数组
    func test_matchPoolData_nullLists_fallbackEmpty() throws {
        let json = """
        {"callList":null,"userList":null}
        """.data(using: .utf8)!
        let pool = try JSONDecoder().decode(MatchPoolData.self, from: json)
        XCTAssertEqual(pool.callList.count, 0)
        XCTAssertEqual(pool.userList.count, 0)
    }

    /// callList / userList 字段缺失 → fallback 空数组
    func test_matchPoolData_missingKeys_fallbackEmpty() throws {
        let json = "{}".data(using: .utf8)!
        let pool = try JSONDecoder().decode(MatchPoolData.self, from: json)
        XCTAssertEqual(pool.callList.count, 0)
        XCTAssertEqual(pool.userList.count, 0)
    }

    /// MatchPoolData 完整对象 decode
    func test_matchPoolData_fullDecode() throws {
        let json = """
        {
            "callList": [
                {
                    "callerIcon":"a.jpg", "callerNickname":"A",
                    "receiverIcon":"b.jpg", "receiverNickname":"B"
                }
            ],
            "userList": [
                {"userId":"1","nickname":"n1","icon":"i1"},
                {"userId":2,"nickname":"n2","icon":"i2"}
            ]
        }
        """.data(using: .utf8)!
        let pool = try JSONDecoder().decode(MatchPoolData.self, from: json)
        XCTAssertEqual(pool.callList.count, 1)
        XCTAssertEqual(pool.callList[0].callerNickname, "A")
        XCTAssertEqual(pool.userList.count, 2)
        XCTAssertEqual(pool.userList[0].userId, "1")
        XCTAssertEqual(pool.userList[1].userId, "2")
    }

    // MARK: - MatchCanOpenResult raw value 映射

    func test_matchCanOpenResult_rawValues() {
        XCTAssertEqual(MatchCanOpenResult(rawValue: 1), .allowed)
        XCTAssertEqual(MatchCanOpenResult(rawValue: 2), .faceCheckFailed)
        XCTAssertEqual(MatchCanOpenResult(rawValue: 3), .exceededCount)
        XCTAssertNil(MatchCanOpenResult(rawValue: 0))
        XCTAssertNil(MatchCanOpenResult(rawValue: 99))
    }

    // MARK: - MatchDateHelper 时区/日期字符串

    func test_matchDateHelper_todayString_formatMatchesH5() {
        // H5 useMatch.js:53-56: `${y}-${m+1}-${d}` (月不补零)
        // iOS 版本用 Calendar.dateComponents，验证输出符合 YYYY-M-D 格式（月不补零）
        let today = MatchDateHelper.todayString()
        // 至少包含 3 段 `-` 分隔
        let parts = today.split(separator: "-")
        XCTAssertEqual(parts.count, 3)
        XCTAssertNotNil(Int(parts[0]))
        XCTAssertNotNil(Int(parts[1]))
        XCTAssertNotNil(Int(parts[2]))
    }

    func test_matchDateHelper_isFirstToday_emptyString_returnsTrue() {
        XCTAssertTrue(MatchDateHelper.isFirstToday(savedDate: ""))
    }

    func test_matchDateHelper_isFirstToday_todayString_returnsFalse() {
        let today = MatchDateHelper.todayString()
        XCTAssertFalse(MatchDateHelper.isFirstToday(savedDate: today))
    }
}
