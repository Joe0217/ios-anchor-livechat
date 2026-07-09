import XCTest

/// H-2 v2 分类语义对齐 H5（3 独立 filter，可重叠）。
///
/// **H5 语义**（`src/stores/modules/session.js:130-167`）：
/// - `filterSessionsByFlame`：ext 通道 A **OR** flameUserIdSet（关注列表）
/// - `filterSessionsByPrimeLevelLimit`：只看 primeUidSet，**不排除 Flame**
/// - `filterSessionsByStranger`：只排除 Flame，**不排除 Prime**
final class MessageSessionClassifierTests: XCTestCase {

    // MARK: - Flame 通道 A（ext 字段）—— H5 逐字对齐 boolean AND 语义

    func test_flame_by_receivedGift() {
        let s = MessageSessionFactory.make(id: "u1", ext: MessageSessionExt(
            receivedGift: true, called: false, received: false, sended: false))
        XCTAssertTrue(MessageSessionClassifier.isFlame(s, flameUserIdSet: []))
    }

    func test_flame_by_called() {
        let s = MessageSessionFactory.make(id: "u1", ext: MessageSessionExt(
            receivedGift: false, called: true, received: false, sended: false))
        XCTAssertTrue(MessageSessionClassifier.isFlame(s, flameUserIdSet: []))
    }

    func test_flame_by_received_AND_sended_boolean_AND() {
        // H5 逐字对齐：received && sended 而非 received + sended > 0
        let s = MessageSessionFactory.make(id: "u1", ext: MessageSessionExt(
            receivedGift: false, called: false, received: true, sended: true))
        XCTAssertTrue(MessageSessionClassifier.isFlame(s, flameUserIdSet: []))
    }

    /// H5 boolean AND 边界：received=true 但 sended=false → 不满足 AND，通道 A 不命中
    func test_received_only_without_sended_not_flame_via_ext() {
        let s = MessageSessionFactory.make(id: "u1", ext: MessageSessionExt(
            receivedGift: false, called: false, received: true, sended: false))
        XCTAssertFalse(MessageSessionClassifier.isFlame(s, flameUserIdSet: []))
    }

    /// H5 boolean AND 边界：sended=true 但 received=false → 不满足 AND，通道 A 不命中
    func test_sended_only_without_received_not_flame_via_ext() {
        let s = MessageSessionFactory.make(id: "u1", ext: MessageSessionExt(
            receivedGift: false, called: false, received: false, sended: true))
        XCTAssertFalse(MessageSessionClassifier.isFlame(s, flameUserIdSet: []))
    }

    // MARK: - Flame 通道 B（关注列表）—— H-2 v2 新增

    /// 关注列表命中 → Flame（哪怕 ext 全 false）
    func test_flame_by_follow_list_only() {
        let s = MessageSessionFactory.make(id: "u1", ext: .empty)
        XCTAssertTrue(MessageSessionClassifier.isFlame(s, flameUserIdSet: ["u1"]))
    }

    /// ext 全 false + 不在关注列表 → 不 Flame
    func test_not_flame_when_ext_empty_and_not_followed() {
        let s = MessageSessionFactory.make(id: "u1", ext: .empty)
        XCTAssertFalse(MessageSessionClassifier.isFlame(s, flameUserIdSet: ["other"]))
    }

    // MARK: - Prime 独立 —— 不排除 Flame

    func test_prime_hits_uid_set() {
        let s = MessageSessionFactory.make(id: "u1", ext: .empty)
        XCTAssertTrue(MessageSessionClassifier.isPrime(s, primeUidSet: ["u1"]))
    }

    /// 关键 · Prime 和 Flame 可重叠（H5 `filterSessionsByPrimeLevelLimit` 不排除 Flame）
    func test_prime_and_flame_can_overlap() {
        let s = MessageSessionFactory.make(id: "u1", ext: MessageSessionExt(
            receivedGift: true, called: false, received: false, sended: false))
        XCTAssertTrue(MessageSessionClassifier.isFlame(s, flameUserIdSet: []))
        XCTAssertTrue(MessageSessionClassifier.isPrime(s, primeUidSet: ["u1"]))
    }

    /// 关键 · 关注的 Prime 用户同时命中 Flame（通道 B）和 Prime —— 本次修复的核心 case
    func test_followed_prime_user_in_both_flame_and_prime() {
        let s = MessageSessionFactory.make(id: "u1", ext: .empty)
        XCTAssertTrue(MessageSessionClassifier.isFlame(s, flameUserIdSet: ["u1"]),
                      "关注列表命中 → Flame（H-2 v2 修复：H-1 单归一时会归 Prime，与 H5 不一致）")
        XCTAssertTrue(MessageSessionClassifier.isPrime(s, primeUidSet: ["u1"]),
                      "同时也在 Prime tab（H5 filterSessionsByPrimeLevelLimit 不排除 Flame）")
    }

    // MARK: - Stranger 独立 —— 只排除 Flame，不排除 Prime

    func test_stranger_only_excludes_flame() {
        let s = MessageSessionFactory.make(id: "u1", ext: .empty)
        XCTAssertTrue(MessageSessionClassifier.isStranger(s, flameUserIdSet: []),
                      "既不 Flame（无 ext + 无关注）→ Stranger")
    }

    /// Flame 命中 → 不是 Stranger
    func test_flame_excludes_stranger() {
        let s = MessageSessionFactory.make(id: "u1", ext: MessageSessionExt(
            receivedGift: true, called: false, received: false, sended: false))
        XCTAssertFalse(MessageSessionClassifier.isStranger(s, flameUserIdSet: []))
    }

    /// 关注命中 → 不是 Stranger（通道 B）
    func test_followed_user_excludes_stranger() {
        let s = MessageSessionFactory.make(id: "u1", ext: .empty)
        XCTAssertFalse(MessageSessionClassifier.isStranger(s, flameUserIdSet: ["u1"]))
    }

    /// 关键 · Stranger 可以是 Prime（H5 filterSessionsByStranger 不排除 Prime）
    func test_prime_user_not_followed_can_be_stranger() {
        let s = MessageSessionFactory.make(id: "u1", ext: .empty)
        XCTAssertTrue(MessageSessionClassifier.isStranger(s, flameUserIdSet: []),
                      "Prime 用户 + 未关注 + 无 ext → **同时在 Stranger 和 Prime tab**（H5 语义如此）")
        XCTAssertTrue(MessageSessionClassifier.isPrime(s, primeUidSet: ["u1"]))
    }

    // MARK: - v7 · activeTycoon 通道（对齐安卓 MsgMainFragment.isFlame #5/#6）

    /// 安卓 #6：ext.activeTycoon = true → Flame（profile 为空时兜底判定）
    func test_flame_by_ext_active_tycoon() {
        let s = MessageSessionFactory.make(id: "u1", ext: MessageSessionExt(
            receivedGift: false, called: false, received: false, sended: false, activeTycoon: true))
        XCTAssertTrue(MessageSessionClassifier.isFlame(s, flameUserIdSet: []),
                      "ext.activeTycoon = true → Flame（对齐安卓 #6）")
    }

    /// 安卓 #5：profile.activeTycoon = true → Flame（服务端身份标签）
    func test_flame_by_profile_active_tycoon() {
        let s = MessageSessionFactory.make(id: "u1", ext: .empty)
        XCTAssertTrue(MessageSessionClassifier.isFlame(s, flameUserIdSet: [], profileActiveTycoon: true),
                      "profile.activeTycoon = true → Flame（对齐安卓 #5）")
    }

    /// activeTycoon 用户 + 未关注 + 无 ext → 仍归 Flame（activeTycoon 单独一路命中）
    func test_active_tycoon_alone_is_flame() {
        let s = MessageSessionFactory.make(id: "u1", ext: .empty)
        XCTAssertFalse(MessageSessionClassifier.isFlame(s, flameUserIdSet: []),
                       "无任何 activeTycoon 信号 → 不是 Flame")
        XCTAssertTrue(MessageSessionClassifier.isFlame(s, flameUserIdSet: [], profileActiveTycoon: true),
                      "加上 profileActiveTycoon → Flame")
    }

    /// activeTycoon 用户在 Flame → 从 Stranger 移除（对齐 Stranger = !isFlame）
    func test_active_tycoon_excludes_stranger() {
        let s = MessageSessionFactory.make(id: "u1", ext: .empty)
        XCTAssertFalse(MessageSessionClassifier.isStranger(s, flameUserIdSet: [], profileActiveTycoon: true))
    }
}
