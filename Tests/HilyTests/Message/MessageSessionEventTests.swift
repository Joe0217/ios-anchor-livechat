import XCTest

/// H-1 spec §2.2 合并语义 + §3.3 R-3-b 单测覆盖。
final class MessageSessionEventTests: XCTestCase {

    func test_merge_single_add_preserved() {
        let s = MessageSessionFactory.make(id: "u1")
        let events: [MessageSessionEvent] = [.add(s)]
        XCTAssertEqual(events.mergedByLastTerminal(), [.add(s)])
    }

    func test_merge_add_then_update_keeps_last_update() {
        let s1 = MessageSessionFactory.make(id: "u1", timestamp: 100)
        let s2 = MessageSessionFactory.make(id: "u1", timestamp: 200)
        let events: [MessageSessionEvent] = [.add(s1), .update(s2)]
        XCTAssertEqual(events.mergedByLastTerminal(), [.update(s2)])
    }

    func test_merge_update_then_update_keeps_last() {
        let s1 = MessageSessionFactory.make(id: "u1", timestamp: 100)
        let s2 = MessageSessionFactory.make(id: "u1", timestamp: 200)
        let events: [MessageSessionEvent] = [.update(s1), .update(s2)]
        XCTAssertEqual(events.mergedByLastTerminal(), [.update(s2)])
    }

    /// R-3-b: 同 sessionId add + remove → 仅保留 remove（终态优先）
    func test_merge_add_then_remove_yields_only_remove() {
        let s = MessageSessionFactory.make(id: "u1")
        let events: [MessageSessionEvent] = [.add(s), .remove(sessionId: "u1")]
        XCTAssertEqual(events.mergedByLastTerminal(), [.remove(sessionId: "u1")])
    }

    /// R-3-b: 同 sessionId update + remove → 仅保留 remove
    func test_conflicting_update_remove_for_same_sessionId_remove_wins() {
        let s = MessageSessionFactory.make(id: "u1", timestamp: 100)
        let events: [MessageSessionEvent] = [.update(s), .remove(sessionId: "u1")]
        XCTAssertEqual(events.mergedByLastTerminal(), [.remove(sessionId: "u1")])
    }

    /// R-3-b: remove 一旦出现，后续 add/update 被吞（remove 终态吸收）
    func test_remove_swallows_following_add() {
        let s = MessageSessionFactory.make(id: "u1")
        let events: [MessageSessionEvent] = [.remove(sessionId: "u1"), .add(s)]
        XCTAssertEqual(events.mergedByLastTerminal(), [.remove(sessionId: "u1")])
    }

    /// 稳定排序：按首次出现顺序
    func test_merge_preserves_first_occurrence_order() {
        let a = MessageSessionFactory.make(id: "a")
        let b = MessageSessionFactory.make(id: "b")
        let c = MessageSessionFactory.make(id: "c")
        let events: [MessageSessionEvent] = [.add(a), .add(b), .update(a), .add(c)]
        // 期望顺序 a → b → c（a 的 update 覆盖 a 的 add；顺序按首次出现）
        let result = events.mergedByLastTerminal()
        XCTAssertEqual(result.map(\.sessionId), ["a", "b", "c"])
        XCTAssertEqual(result[0], .update(a))
        XCTAssertEqual(result[1], .add(b))
        XCTAssertEqual(result[2], .add(c))
    }

    func test_isTerminal_only_remove() {
        XCTAssertTrue(MessageSessionEvent.remove(sessionId: "u1").isTerminal)
        XCTAssertFalse(MessageSessionEvent.add(MessageSessionFactory.make(id: "u1")).isTerminal)
        XCTAssertFalse(MessageSessionEvent.update(MessageSessionFactory.make(id: "u1")).isTerminal)
    }

    func test_sessionId_extraction() {
        let s = MessageSessionFactory.make(id: "u1")
        XCTAssertEqual(MessageSessionEvent.add(s).sessionId, "u1")
        XCTAssertEqual(MessageSessionEvent.update(s).sessionId, "u1")
        XCTAssertEqual(MessageSessionEvent.remove(sessionId: "u1").sessionId, "u1")
    }
}
