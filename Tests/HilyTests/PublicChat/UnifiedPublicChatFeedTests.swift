import XCTest
@testable import HilyTests

@MainActor
final class UnifiedPublicChatFeedTests: XCTestCase {

    func test_append_adds_message() {
        let feed = UnifiedPublicChatFeed(limit: 5)
        let msg = UnifiedPublicChatMessage(variant: .system(text: "hi"))
        feed.append(msg)
        XCTAssertEqual(feed.messages.count, 1)
        XCTAssertEqual(feed.messages[0].id, msg.id)
    }

    func test_append_trims_when_limit_exceeded() {
        let feed = UnifiedPublicChatFeed(limit: 3)
        (0..<10).forEach { i in
            feed.append(UnifiedPublicChatMessage(variant: .system(text: "\(i)")))
        }
        XCTAssertEqual(feed.messages.count, 3)
        if case .system(let text) = feed.messages[0].variant {
            XCTAssertEqual(text, "7")
        } else { XCTFail("expected system") }
    }

    func test_appendBatch_extends_all() {
        let feed = UnifiedPublicChatFeed(limit: 100)
        let batch = (0..<5).map { UnifiedPublicChatMessage(variant: .system(text: "\($0)")) }
        feed.appendBatch(batch)
        XCTAssertEqual(feed.messages.count, 5)
    }

    func test_clear_removes_all() {
        let feed = UnifiedPublicChatFeed()
        feed.append(UnifiedPublicChatMessage(variant: .system(text: "hi")))
        feed.clear()
        XCTAssertTrue(feed.messages.isEmpty)
    }

    func test_replace_overwrites_all_and_trims() {
        let feed = UnifiedPublicChatFeed(limit: 3)
        feed.append(UnifiedPublicChatMessage(variant: .system(text: "old")))
        let newBatch = (0..<5).map { UnifiedPublicChatMessage(variant: .system(text: "\($0)")) }
        feed.replace(newBatch)
        XCTAssertEqual(feed.messages.count, 3)
        if case .system(let t) = feed.messages[0].variant { XCTAssertEqual(t, "2") } else { XCTFail() }
    }
}
