import XCTest

final class LoginResultDecodeTests: XCTestCase {
    func testDecodesNumericAndStringAuditStateFields() throws {
        let data = Data("""
        {
          "userId": 7,
          "token": "token",
          "userType": "1",
          "valid": "1",
          "onReview": 1,
          "banAlways": "0",
          "bannedSubType": "24"
        }
        """.utf8)

        let result = try JSONDecoder().decode(LoginResult.self, from: data)

        XCTAssertEqual(result.userType, 1)
        XCTAssertEqual(result.valid, 1)
        XCTAssertEqual(result.onReview, true)
        XCTAssertEqual(result.banAlways, false)
        XCTAssertEqual(result.bannedSubType, 24)
    }

    func testFallsBackFromTypeWhenUserTypeIsAbsent() throws {
        let data = Data("{ \"token\": \"token\", \"type\": \"2\", \"onReview\": false }".utf8)

        let result = try JSONDecoder().decode(LoginResult.self, from: data)

        XCTAssertEqual(result.userType, 2)
        XCTAssertEqual(result.type, 2)
        XCTAssertEqual(result.onReview, false)
    }

    func testMissingRoleFieldsRemainNilForFailClosedRouting() throws {
        let result = try JSONDecoder().decode(LoginResult.self, from: Data("{ \"token\": \"token\" }".utf8))

        XCTAssertNil(result.userType)
        XCTAssertNil(result.type)
    }

    func testDecodesRefreshedAnchorAuditState() throws {
        let data = Data("""
        {
          "userType": "2",
          "valid": "1",
          "onReview": 0,
          "banAlways": 1,
          "bannedSubType": "12"
        }
        """.utf8)

        let result = try JSONDecoder().decode(AnchorInfo.self, from: data)

        XCTAssertEqual(result.userType, 2)
        XCTAssertEqual(result.valid, 1)
        XCTAssertEqual(result.onReview, false)
        XCTAssertEqual(result.banAlways, true)
        XCTAssertEqual(result.bannedSubType, 12)
    }
}
