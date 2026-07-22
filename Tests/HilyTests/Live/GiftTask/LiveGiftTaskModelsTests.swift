import XCTest

/// spec §1.4 tc-1a-7 部分 + §5.2 R-3/R-6/R-26 覆盖:GiftTaskProgress 与 GiftHistoryItem decode 边界。
final class LiveGiftTaskModelsTests: XCTestCase {

    // MARK: - GiftTaskProgress

    func testGiftTaskProgress_decodeInt() throws {
        let json = #"{"giftTotal": 1200, "taskAmount": 5000}"#.data(using: .utf8)!
        let progress = try JSONDecoder().decode(GiftTaskProgress.self, from: json)
        XCTAssertEqual(progress.giftTotal, 1200)
        XCTAssertEqual(progress.taskAmount, 5000)
        XCTAssertTrue(progress.hasActiveTask)
        XCTAssertEqual(progress.ratio, 0.24, accuracy: 0.001)
    }

    func testGiftTaskProgress_decodeStringFlexible() throws {
        // 后端偶发返 String,decodeFlexibleInt 兜底
        let json = #"{"giftTotal": "3000", "taskAmount": "5000"}"#.data(using: .utf8)!
        let progress = try JSONDecoder().decode(GiftTaskProgress.self, from: json)
        XCTAssertEqual(progress.giftTotal, 3000)
        XCTAssertEqual(progress.taskAmount, 5000)
    }

    /// R-26: response 缺 taskAmount → nil → icon 隐藏
    func testGiftTaskProgress_missingTaskAmount() throws {
        let json = #"{"giftTotal": 1000}"#.data(using: .utf8)!
        let progress = try JSONDecoder().decode(GiftTaskProgress.self, from: json)
        XCTAssertEqual(progress.giftTotal, 1000)
        XCTAssertNil(progress.taskAmount)
        XCTAssertFalse(progress.hasActiveTask)
        XCTAssertEqual(progress.ratio, 0.0)
    }

    /// tc-1a-7 边界:taskAmount=0 视为无任务
    func testGiftTaskProgress_taskAmountZero() throws {
        let json = #"{"giftTotal": 500, "taskAmount": 0}"#.data(using: .utf8)!
        let progress = try JSONDecoder().decode(GiftTaskProgress.self, from: json)
        XCTAssertEqual(progress.taskAmount, 0)
        XCTAssertFalse(progress.hasActiveTask)
        XCTAssertEqual(progress.ratio, 0.0)
    }

    /// R-3 除零保护:taskAmount=0 时 ratio=0 不 crash
    func testGiftTaskProgress_ratioDivideByZeroSafe() {
        let progress = GiftTaskProgress(giftTotal: 999, taskAmount: 0)
        XCTAssertEqual(progress.ratio, 0.0)
    }

    /// giftTotal 超过 taskAmount → ratio 硬夹到 1.0
    func testGiftTaskProgress_ratioClampToOne() {
        let progress = GiftTaskProgress(giftTotal: 10_000, taskAmount: 5_000)
        XCTAssertEqual(progress.ratio, 1.0)
    }

    // MARK: - GiftHistoryItem

    /// R-6: userId 缺失 → 空字符串 fallback,不 crash
    func testGiftHistoryItem_userIdMissing() throws {
        let json = #"{"nickname": "Alice", "giftIcon": "", "giftNum": 3, "formattedTime": "5m ago", "icon": ""}"#
            .data(using: .utf8)!
        let item = try JSONDecoder().decode(GiftHistoryItem.self, from: json)
        XCTAssertEqual(item.userId, "")
        XCTAssertEqual(item.nickname, "Alice")
        XCTAssertEqual(item.giftNum, 3)
    }

    /// userId String/Int 双兼容
    func testGiftHistoryItem_userIdIntFlexible() throws {
        let json = #"{"userId": 12345, "nickname": "Bob", "giftIcon": "", "giftNum": 1, "formattedTime": "", "icon": ""}"#
            .data(using: .utf8)!
        let item = try JSONDecoder().decode(GiftHistoryItem.self, from: json)
        XCTAssertEqual(item.userId, "12345")
    }

    /// giftNum 后端偶发返 String,decodeFlexibleInt 兜底
    func testGiftHistoryItem_giftNumStringFlexible() throws {
        let json = #"{"userId": "1", "nickname": "C", "giftIcon": "", "giftNum": "7", "formattedTime": "", "icon": ""}"#
            .data(using: .utf8)!
        let item = try JSONDecoder().decode(GiftHistoryItem.self, from: json)
        XCTAssertEqual(item.giftNum, 7)
    }

    /// 全字段缺失 → 各 fallback 空/0,不抛
    func testGiftHistoryItem_allFieldsMissing() throws {
        let json = "{}".data(using: .utf8)!
        let item = try JSONDecoder().decode(GiftHistoryItem.self, from: json)
        XCTAssertEqual(item.userId, "")
        XCTAssertEqual(item.nickname, "")
        XCTAssertEqual(item.giftNum, 0)
        XCTAssertNil(item.headFrame)
        XCTAssertNil(item.activeTycoon)
    }

    /// R-27: IndexedGiftHistoryItem id 稳定 = "p{page}r{row}",避免拼串因 formattedTime 冲突
    func testIndexedGiftHistoryItem_stableId() {
        let raw = GiftHistoryItem(userId: "u1", icon: "", nickname: "A",
                                  formattedTime: "3m ago", giftIcon: "", giftNum: 1)
        let a = IndexedGiftHistoryItem(page: 1, row: 5, item: raw)
        let b = IndexedGiftHistoryItem(page: 1, row: 5, item: raw)
        XCTAssertEqual(a.id, "p1r5")
        XCTAssertEqual(a.id, b.id)

        let differentRow = IndexedGiftHistoryItem(page: 1, row: 6, item: raw)
        XCTAssertNotEqual(a.id, differentRow.id)
    }
}
