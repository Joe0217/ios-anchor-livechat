import XCTest

@MainActor
final class PublicChatMessagesStoreTests: XCTestCase {

    func testDefaultLimitKeepsLatestFiftyMessages() {
        let store = PublicChatMessagesStore()

        for index in 0...50 {
            store.append(PublicChatMessage(text: "\(index)", isSystem: true))
        }

        XCTAssertEqual(store.messages.count, 50)
        XCTAssertEqual(store.messages.first?.text, "1")
        XCTAssertEqual(store.messages.last?.text, "50")
    }

    func testClearRemovesAllMessages() {
        let store = PublicChatMessagesStore()
        store.append(PublicChatMessage(text: "message", isSystem: false))

        store.clear()

        XCTAssertTrue(store.messages.isEmpty)
    }
}
