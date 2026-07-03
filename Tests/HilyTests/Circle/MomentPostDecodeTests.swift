import XCTest

/// trial #1 (A-spec §1.4 + 步 1c) — `MomentPost` Codable decode 单测。
///
/// **价值**：步 1c "Fakes 数据层"的异常行为之一是"返回非法字段"。这里聚焦
/// `MomentPost` decode 路径 — 后端字段变更（拼写错 / 类型偷换 / 字段缺失）单测立刻挂。
///
/// 特别验证 spec §1.4 第 2 项现存 bug 修复：CodingKey 别名 `likeNum → likeCount` / `commentNum → commentCount`。
/// 旧版无别名 → Codable 默认按属性名匹配 → likeCount / commentCount 永远 nil；本测试反向证伪该 bug 已修。
final class MomentPostDecodeTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - 完整字段

    func test_decode_fullPayload_allFieldsMapCorrectly() throws {
        // trial step 3 真集成反悔：createTime 实际是字符串 (H5 type.ts:25)，
        // 步 1a 写成 Int? 是 spec §1.4 第 3 项遗留 bug，已修
        let json = """
        {
          "id": 1001,
          "userId": 2001,
          "nickname": "Sarah",
          "icon": "https://example.com/a.png",
          "textContent": "Hello, world",
          "imgUrls": ["https://example.com/1.jpg", "https://example.com/2.jpg"],
          "createTime": "2024-01-15 12:34:56",
          "likeNum": 25,
          "commentNum": 7,
          "likeFlag": 1,
          "displayRange": 1
        }
        """.data(using: .utf8)!

        let post = try decoder.decode(MomentPost.self, from: json)
        XCTAssertEqual(post.postId, 1001)
        XCTAssertEqual(post.userId, 2001)
        XCTAssertEqual(post.nickname, "Sarah")
        XCTAssertEqual(post.icon, "https://example.com/a.png")
        XCTAssertEqual(post.textContent, "Hello, world")
        XCTAssertEqual(post.imgUrls, ["https://example.com/1.jpg", "https://example.com/2.jpg"])
        XCTAssertEqual(post.createTime, "2024-01-15 12:34:56", "createTime 是字符串 (H5 type.ts:25 / 真机抓包)")
        XCTAssertEqual(post.likeCount, 25, "likeNum 应映射到 likeCount (spec §1.4 第 2 项现存 bug 修复)")
        XCTAssertEqual(post.commentCount, 7, "commentNum 应映射到 commentCount")
        XCTAssertEqual(post.likeFlag, 1)
        XCTAssertEqual(post.displayRange, 1)
    }

    // MARK: - createTime 是字符串（trial step 3 反悔证伪：数字应失败）

    func test_decode_createTimeAsNumber_fails() {
        // 反向证伪：如果后端将来把 createTime 改回数字，单测应立刻挂
        let json = """
        { "id": 1, "createTime": 1700000000000 }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try decoder.decode(MomentPost.self, from: json)) { error in
            XCTAssertTrue(error is DecodingError, "createTime 是字符串约定，数字应抛 DecodingError")
        }
    }

    // MARK: - 字段缺失（Optional 字段返 nil，不抛错）

    func test_decode_missingOptionalFields_returnsNil() throws {
        // 真实响应可能字段不全 — Optional 字段应 nil 而非 decode 失败
        let json = """
        { "id": 100 }
        """.data(using: .utf8)!

        let post = try decoder.decode(MomentPost.self, from: json)
        XCTAssertEqual(post.postId, 100)
        XCTAssertNil(post.likeCount)
        XCTAssertNil(post.commentCount)
        XCTAssertNil(post.likeFlag)
        XCTAssertNil(post.imgUrls)
    }

    // MARK: - 字段类型偷换 — 必须 decode 失败保证后端兼容性

    func test_decode_likeNumAsString_fails() {
        // 后端如果偷偷把 likeNum 改为 String，单测应立刻挂
        let json = """
        { "id": 1, "likeNum": "25" }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try decoder.decode(MomentPost.self, from: json)) { error in
            // DecodingError.typeMismatch
            XCTAssertTrue(error is DecodingError, "类型偷换应抛 DecodingError, got \(error)")
        }
    }

    func test_decode_likeFlagAsString_fails() {
        let json = """
        { "id": 1, "likeFlag": "1" }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try decoder.decode(MomentPost.self, from: json)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    // MARK: - 旧字段名不被误映射（反向证伪 CodingKey 必要性）

    func test_decode_legacyLikeCountField_doesNotMap() throws {
        // 如果后端发"likeCount"字段（与 iOS 属性同名但与新约定 likeNum 不一致）
        // CodingKey 设了 `likeCount = "likeNum"` 后，按 key="likeNum" 匹配 → 找不到 → likeCount=nil
        // 验证 CodingKey 别名生效（旧字段名不被偷偷映射）
        let json = """
        { "id": 1, "likeCount": 99 }
        """.data(using: .utf8)!

        let post = try decoder.decode(MomentPost.self, from: json)
        XCTAssertNil(post.likeCount, "iOS 属性 likeCount 应只接受 key='likeNum'，旧 key='likeCount' 不映射")
    }

    // MARK: - imgUrls 各种态

    func test_decode_imgUrls_empty_array_isAllowed() throws {
        let json = """
        { "id": 1, "imgUrls": [] }
        """.data(using: .utf8)!

        let post = try decoder.decode(MomentPost.self, from: json)
        XCTAssertEqual(post.imgUrls, [])
    }

    func test_decode_imgUrls_missing_isNil() throws {
        let json = """
        { "id": 1 }
        """.data(using: .utf8)!

        let post = try decoder.decode(MomentPost.self, from: json)
        XCTAssertNil(post.imgUrls)
    }

    // MARK: - id 由 postId + createTime 派生（Identifiable）

    func test_id_composedFromPostIdAndCreateTime() throws {
        let json = """
        { "id": 100, "createTime": "2024-01-15T12:34:56Z" }
        """.data(using: .utf8)!

        let post = try decoder.decode(MomentPost.self, from: json)
        XCTAssertEqual(post.id, "100-2024-01-15T12:34:56Z", "Identifiable.id = postId-createTime")
    }

    func test_id_handlesNilFields() throws {
        let json = """
        { "id": null }
        """.data(using: .utf8)!

        let post = try decoder.decode(MomentPost.self, from: json)
        XCTAssertEqual(post.id, "-1-", "缺字段时 id 用 -1/空字符串兜底")
    }
}
