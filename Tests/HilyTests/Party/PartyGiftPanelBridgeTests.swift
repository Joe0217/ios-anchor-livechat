import XCTest
// 待测源码通过 project.yml HilyTests.sources 编入；同 module 无需 @testable import

/// H-5 派对房礼物面板 Bridge 单测（spec §5 · R14 + owner 优先 + fallback + 空过滤）。
///
/// 覆盖 `PartyGiftPanelBridge.makeReceiversConfig` 的 4 类分支：
/// 1. R14 · seat.yxAccid nil/空串/"0" → 该 seat 不进 items（对齐 H5 party-gift-popup.vue L149）
/// 2. seat.userId nil/空串 **不影响 items 入列**（H5 只依赖 yxAccid，不看 userId）
/// 3. 过滤自己（selfYxAccid == seat.yxAccid；对齐 H5）
/// 4. 默认单选：owner 优先 → 否则第一个有效 yxAccid
/// 5. 全部过滤后 items 空 + initialSelection 空（对齐 spec R8 empty state 前置）
final class PartyGiftPanelBridgeTests: XCTestCase {

    /// 快捷构造 PartyRoomSeat（仅关注 bridge 用到的字段；其他 optional 全 nil）
    private func seat(index: Int? = 1,
                      userId: String? = "u1",
                      yxAccid: String? = "yx1",
                      role: Int? = nil,
                      avatar: String? = nil) -> PartyRoomSeat {
        PartyRoomSeat(
            id: nil,
            roomId: nil,
            seatIndex: index,
            userId: userId,
            avatar: avatar,
            nickname: nil,
            seatType: nil,
            isOccupied: (userId != nil && !(userId?.isEmpty ?? true)) ? 1 : 0,
            cameraEnabled: nil,
            microphoneEnabled: nil,
            roomRoleType: role,
            giftValueCount: nil,
            headFrame: nil,
            yxAccid: yxAccid,
            userType: nil,
            seatCameraEnabled: nil,
            seatMicrophoneEnabled: nil,
            lockFlag: nil,
            roomTempId: nil,
            isHostSeat: nil,
            isPlatformAdmin: nil,
            showBubble: nil,
            anchorTaskRewardExt: nil
        )
    }

    // MARK: - R14 & 空字段过滤（对齐 H5 只看 yxAccid）

    func test_R14_yxAccidEmpty_excludedFromItems() {
        let seats = [
            seat(index: 1, userId: "u1", yxAccid: nil),        // yxAccid nil
            seat(index: 2, userId: "u2", yxAccid: ""),         // yxAccid 空串
            seat(index: 3, userId: "u3", yxAccid: "yx3"),      // 有效
        ]
        let cfg = PartyGiftPanelBridge.makeReceiversConfig(seatList: seats, selfYxAccid: nil)
        XCTAssertEqual(cfg.items.count, 1)
        XCTAssertEqual(cfg.items.first?.id, "yx3")
    }

    func test_PA1_yxAccidZero_excludedFromItems() {
        // 对齐 H5 party-gift-popup.vue L149：yxAccid == "0" 视为占位，排除
        let seats = [
            seat(index: 1, userId: "u1", yxAccid: "0"),        // 占位
            seat(index: 2, userId: "u2", yxAccid: "yx2"),      // 有效
        ]
        let cfg = PartyGiftPanelBridge.makeReceiversConfig(seatList: seats, selfYxAccid: nil)
        XCTAssertEqual(cfg.items.count, 1)
        XCTAssertEqual(cfg.items.first?.id, "yx2")
    }

    func test_userIdNil_stillIncluded_alignH5() {
        // H5 不要求 userId 非空，只看 yxAccid。iOS 2026-07-14 修订后对齐
        let seats = [
            seat(index: 1, userId: nil, yxAccid: "yx1"),
            seat(index: 2, userId: "", yxAccid: "yx2"),
            seat(index: 3, userId: "u3", yxAccid: "yx3"),
        ]
        let cfg = PartyGiftPanelBridge.makeReceiversConfig(seatList: seats, selfYxAccid: nil)
        XCTAssertEqual(cfg.items.count, 3, "userId nil/空 不影响 items 入列（对齐 H5）")
        XCTAssertEqual(cfg.items.map(\.id), ["yx1", "yx2", "yx3"])
    }

    func test_selfYxAccid_filteredOut() {
        // self 用 yxAccid 匹配（对齐 H5 party-gift-popup.vue L149）
        let seats = [
            seat(index: 1, userId: "me", yxAccid: "yx_me"),
            seat(index: 2, userId: "other", yxAccid: "yx_other"),
        ]
        let cfg = PartyGiftPanelBridge.makeReceiversConfig(seatList: seats, selfYxAccid: "yx_me")
        XCTAssertEqual(cfg.items.count, 1)
        XCTAssertEqual(cfg.items.first?.id, "yx_other")
        XCTAssertEqual(cfg.initialSelection, Set(["yx_other"]))
    }

    // MARK: - 默认单选（owner 优先 → 否则第一个）

    func test_defaultSelection_ownerFirst() {
        let seats = [
            seat(index: 1, userId: "u1", yxAccid: "yx1", role: 3),   // audience
            seat(index: 2, userId: "u2", yxAccid: "yx2", role: 1),   // owner
            seat(index: 3, userId: "u3", yxAccid: "yx3", role: 2),   // admin
        ]
        let cfg = PartyGiftPanelBridge.makeReceiversConfig(seatList: seats, selfYxAccid: nil)
        XCTAssertEqual(cfg.items.count, 3)
        XCTAssertEqual(cfg.initialSelection, Set(["yx2"]),
                       "owner (yx2) 应优先入 initialSelection")
    }

    func test_defaultSelection_fallbackFirst_whenNoOwner() {
        let seats = [
            seat(index: 5, userId: "u5", yxAccid: "yx5", role: 3),
            seat(index: 2, userId: "u2", yxAccid: "yx2", role: 2),
            seat(index: 9, userId: "u9", yxAccid: "yx9", role: nil),
        ]
        let cfg = PartyGiftPanelBridge.makeReceiversConfig(seatList: seats, selfYxAccid: nil)
        // 按 seatIndex 升序：yx2 (index=2) 排第一
        XCTAssertEqual(cfg.items.first?.id, "yx2")
        XCTAssertEqual(cfg.initialSelection, Set(["yx2"]))
    }

    // MARK: - 排序 by seatIndex

    func test_items_sortedBySeatIndex() {
        let seats = [
            seat(index: 5, userId: "u5", yxAccid: "yx5"),
            seat(index: 1, userId: "u1", yxAccid: "yx1"),
            seat(index: 3, userId: "u3", yxAccid: "yx3"),
        ]
        let cfg = PartyGiftPanelBridge.makeReceiversConfig(seatList: seats, selfYxAccid: nil)
        XCTAssertEqual(cfg.items.map(\.id), ["yx1", "yx3", "yx5"])
    }

    // MARK: - R8 · 全过滤后空

    func test_R8_allFilteredOut_itemsEmpty_initialSelectionEmpty() {
        let seats = [
            seat(index: 1, userId: "u1", yxAccid: nil),                // yxAccid nil → 过滤
            seat(index: 2, userId: "me", yxAccid: "yx_me"),            // self → 过滤
            seat(index: 3, userId: "u3", yxAccid: "0"),                // 占位 "0" → 过滤
        ]
        let cfg = PartyGiftPanelBridge.makeReceiversConfig(seatList: seats, selfYxAccid: "yx_me")
        XCTAssertTrue(cfg.items.isEmpty)
        XCTAssertTrue(cfg.initialSelection.isEmpty)
    }

    // MARK: - 空 seatList

    func test_emptySeatList_returnsEmptyConfig() {
        let cfg = PartyGiftPanelBridge.makeReceiversConfig(seatList: [], selfYxAccid: "yx_me")
        XCTAssertTrue(cfg.items.isEmpty)
        XCTAssertTrue(cfg.initialSelection.isEmpty)
        XCTAssertTrue(cfg.allowMultiSelect)
        XCTAssertTrue(cfg.showAllButton)
    }

    // MARK: - allowMultiSelect / showAllButton 契约

    func test_config_flags_areOn() {
        let seats = [seat(index: 1, userId: "u1", yxAccid: "yx1")]
        let cfg = PartyGiftPanelBridge.makeReceiversConfig(seatList: seats, selfYxAccid: nil)
        XCTAssertTrue(cfg.allowMultiSelect, "派对房场景多选默认开")
        XCTAssertTrue(cfg.showAllButton, "派对房场景 All 全选滑块默认开")
    }
}
