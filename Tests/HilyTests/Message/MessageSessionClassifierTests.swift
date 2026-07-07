import XCTest

/// H-1 spec §3.3 反向 R-6 + 正向分类逻辑覆盖。
/// H5 `session.js:34-48` boolean AND 语义逐字对齐（red team C-1 修订）。
final class MessageSessionClassifierTests: XCTestCase {

    // MARK: - 正向

    func test_flame_by_receivedGift() {
        let s = MessageSessionFactory.make(id: "u1", ext: MessageSessionExt(
            receivedGift: true, called: false, received: false, sended: false))
        XCTAssertEqual(MessageSessionClassifier.classify(s, primeUidSet: []), .flame)
    }

    func test_flame_by_called() {
        let s = MessageSessionFactory.make(id: "u1", ext: MessageSessionExt(
            receivedGift: false, called: true, received: false, sended: false))
        XCTAssertEqual(MessageSessionClassifier.classify(s, primeUidSet: []), .flame)
    }

    func test_flame_by_received_AND_sended_boolean_AND() {
        // H5 逐字对齐：received && sended 而非 received + sended > 0
        let s = MessageSessionFactory.make(id: "u1", ext: MessageSessionExt(
            receivedGift: false, called: false, received: true, sended: true))
        XCTAssertEqual(MessageSessionClassifier.classify(s, primeUidSet: []), .flame)
    }

    func test_prime_by_uid_set() {
        let s = MessageSessionFactory.make(id: "u1", ext: .empty)
        XCTAssertEqual(MessageSessionClassifier.classify(s, primeUidSet: ["u1"]), .prime)
    }

    func test_stranger_by_default() {
        let s = MessageSessionFactory.make(id: "u1", ext: .empty)
        XCTAssertEqual(MessageSessionClassifier.classify(s, primeUidSet: []), .stranger)
    }

    func test_flame_wins_over_prime() {
        // 互斥优先级：Flame > Prime
        let s = MessageSessionFactory.make(id: "u1", ext: MessageSessionExt(
            receivedGift: true, called: false, received: false, sended: false))
        XCTAssertEqual(MessageSessionClassifier.classify(s, primeUidSet: ["u1"]), .flame)
    }

    // MARK: - 反向（spec §3.3 R-6）

    /// R-6: 关注/好友无 ext 标记时被误归 Stranger（MVP 已知缺口，明示当前行为）
    func test_relations_without_ext_flag_go_to_stranger() {
        let s = MessageSessionFactory.make(id: "u1", ext: .empty)
        XCTAssertEqual(MessageSessionClassifier.classify(s, primeUidSet: []), .stranger,
                       "MVP 仅 ext 通道 A：无标记的关注/好友归 Stranger，H-2 补 flameUserIdList 通道")
    }

    /// H5 boolean AND 边界：received=true 但 sended=false → 不满足 AND，仍 Stranger
    func test_received_only_without_sended_stays_stranger() {
        let s = MessageSessionFactory.make(id: "u1", ext: MessageSessionExt(
            receivedGift: false, called: false, received: true, sended: false))
        XCTAssertEqual(MessageSessionClassifier.classify(s, primeUidSet: []), .stranger)
    }

    /// H5 boolean AND 边界：sended=true 但 received=false → 不满足 AND，仍 Stranger
    func test_sended_only_without_received_stays_stranger() {
        let s = MessageSessionFactory.make(id: "u1", ext: MessageSessionExt(
            receivedGift: false, called: false, received: false, sended: true))
        XCTAssertEqual(MessageSessionClassifier.classify(s, primeUidSet: []), .stranger)
    }

    // MARK: - classifyAll 批量

    func test_classifyAll_buckets() {
        let sessions = [
            MessageSessionFactory.make(id: "flame", ext: MessageSessionExt(receivedGift: true, called: false, received: false, sended: false)),
            MessageSessionFactory.make(id: "prime", ext: .empty),
            MessageSessionFactory.make(id: "str", ext: .empty),
        ]
        let buckets = MessageSessionClassifier.classifyAll(sessions, primeUidSet: ["prime"])
        XCTAssertEqual(buckets[.flame]?.map(\.id), ["flame"])
        XCTAssertEqual(buckets[.prime]?.map(\.id), ["prime"])
        XCTAssertEqual(buckets[.stranger]?.map(\.id), ["str"])
    }
}
