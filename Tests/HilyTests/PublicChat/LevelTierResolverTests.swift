import XCTest
@testable import HilyTests

final class LevelTierResolverTests: XCTestCase {

    func test_tier_for_levels() {
        XCTAssertEqual(LevelTierResolver.tier(for: 0), 0)
        XCTAssertEqual(LevelTierResolver.tier(for: 9), 0)
        XCTAssertEqual(LevelTierResolver.tier(for: 10), 1)
        XCTAssertEqual(LevelTierResolver.tier(for: 25), 2)
        XCTAssertEqual(LevelTierResolver.tier(for: 99), 9)
        XCTAssertEqual(LevelTierResolver.tier(for: 100), 10)
        XCTAssertEqual(LevelTierResolver.tier(for: 150), 10)
    }

    func test_tier_for_negative_returns_zero() {
        XCTAssertEqual(LevelTierResolver.tier(for: -1), 0)
    }
}
