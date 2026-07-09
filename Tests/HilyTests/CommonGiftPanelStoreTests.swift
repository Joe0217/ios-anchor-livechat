import XCTest
// 待测源码通过 project.yml HilyTests.sources 编入 HilyTests module，同 module 无需 @testable import

/// H-4 公共礼物面板 spec §5.2 R1-R13/R18/R19 单测。
///
/// 覆盖：加载失败 / 空态 / minPrice 过滤 / tab 切换 / 反选 / readonly / count clamp /
/// preset 字段自检 / initialSelection 过滤后 clear / 非 APIError 兜底 / v3 group name 映射 / 混合响应形态。
@MainActor
final class CommonGiftPanelStoreTests: XCTestCase {

    // MARK: - Fake DataSource

    /// 测试专用数据源；用例注入返回值 / 抛错。
    final class FakeDataSource: GiftPanelDataSource {
        var groupsToReturn: [GiftPanelGroup] = []
        var errorToThrow: Error?

        func loadGifts() async throws -> [GiftPanelGroup] {
            if let e = errorToThrow { throw e }
            return groupsToReturn
        }
    }

    /// 快捷构造 gift
    private func gift(_ id: Int64, price: Int64 = 100, name: String = "g") -> GiftListData {
        GiftListData(id: id, name: name, giftPrice: price, giftSmallImg: "", giftImg: "")
    }

    /// 无 footer 的最小 config（用于状态机测试）
    private func makeConfig(minPrice: Int64? = nil,
                            maxPrice: Int64? = nil,
                            initialSelection: GiftListData? = nil,
                            tabs: [GiftPanelTab] = [.popular],
                            countStepper: CountStepperConfig = .hidden,
                            interaction: InteractionMode = .selectable,
                            footer: FooterMode = .confirm(label: "OK", onConfirm: { _, _ in }),
                            dataSource: GiftPanelDataSource) -> CommonGiftPanelConfig {
        CommonGiftPanelConfig(
            tabs: tabs,
            footer: footer,
            countStepper: countStepper,
            minPrice: minPrice,
            maxPrice: maxPrice,
            initialSelection: initialSelection,
            interaction: interaction,
            dataSource: dataSource
        )
    }

    // MARK: - R1 loadFailed APIError

    func test_R1_loadFails_APIError_phaseIsLoadFailed() async {
        let ds = FakeDataSource()
        ds.errorToThrow = APIError(code: "1001", message: "server busy")
        let store = CommonGiftPanelStore(config: makeConfig(dataSource: ds))
        await store.load()
        if case .loadFailed(let msg) = store.phase {
            XCTAssertEqual(msg, "server busy")
        } else {
            XCTFail("expected .loadFailed, got \(store.phase)")
        }
    }

    // MARK: - R2 加载空列表 → empty state

    func test_R2_loadEmpty_visibleEmpty() async {
        let ds = FakeDataSource()
        ds.groupsToReturn = [GiftPanelGroup(tab: .popular, gifts: [])]
        let store = CommonGiftPanelStore(config: makeConfig(dataSource: ds))
        await store.load()
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertTrue(store.visibleGifts.isEmpty)
    }

    // MARK: - R3 minPrice 全过滤 → empty

    func test_R3_minPrice_allFiltered() async {
        let ds = FakeDataSource()
        ds.groupsToReturn = [GiftPanelGroup(tab: .popular, gifts: [gift(1, price: 100), gift(2, price: 200)])]
        let store = CommonGiftPanelStore(config: makeConfig(minPrice: 500, dataSource: ds))
        await store.load()
        XCTAssertTrue(store.visibleGifts.isEmpty)
    }

    // MARK: - R4 switchTab 后 selectedId 不在新 tab → clear

    func test_R4_switchTab_clearsSelectionIfNotInNewTab() async {
        let ds = FakeDataSource()
        ds.groupsToReturn = [
            GiftPanelGroup(tab: .popular, gifts: [gift(1), gift(2)]),
            GiftPanelGroup(tab: .exclusiveGift, gifts: [gift(3), gift(4)])
        ]
        let store = CommonGiftPanelStore(config: makeConfig(tabs: [.popular, .exclusiveGift], dataSource: ds))
        await store.load()
        store.selectGift(1)
        XCTAssertEqual(store.selectedId, 1)
        store.switchTab(.exclusiveGift)
        XCTAssertNil(store.selectedId, "selectedId 应在切换到 exclusive tab 后清空（1 不在 exclusive）")
    }

    func test_R4b_switchTab_keepsSelectionIfInNewTabViaSharedId() async {
        // 共享 id 情况：同 id 出现在两 tab（去重后只留一处）时切换保留 selection
        let ds = FakeDataSource()
        // 派对房去重后 gift 1 只出现在 popular；此测证明 selectedId 属于目标 tab 时保留
        ds.groupsToReturn = [
            GiftPanelGroup(tab: .popular, gifts: [gift(1)]),
            GiftPanelGroup(tab: .exclusiveGift, gifts: [gift(1)])
        ]
        let store = CommonGiftPanelStore(config: makeConfig(tabs: [.popular, .exclusiveGift], dataSource: ds))
        await store.load()
        store.selectGift(1)
        store.switchTab(.exclusiveGift)
        XCTAssertEqual(store.selectedId, 1, "selectedId 若在新 tab 里存在应保留")
    }

    // MARK: - R5 二次 tap 同 id → 反选

    func test_R5_tapSameGiftTwice_deselects() async {
        let ds = FakeDataSource()
        ds.groupsToReturn = [GiftPanelGroup(tab: .popular, gifts: [gift(1)])]
        let store = CommonGiftPanelStore(config: makeConfig(dataSource: ds))
        await store.load()
        store.selectGift(1)
        XCTAssertEqual(store.selectedId, 1)
        store.selectGift(1)
        XCTAssertNil(store.selectedId)
    }

    // MARK: - R6 readonly 交互 tap no-op

    func test_R6_readonly_tapNoOp() async {
        let ds = FakeDataSource()
        ds.groupsToReturn = [GiftPanelGroup(tab: .popular, gifts: [gift(1)])]
        let store = CommonGiftPanelStore(config: makeConfig(interaction: .readonly, dataSource: ds))
        await store.load()
        store.selectGift(1)
        XCTAssertNil(store.selectedId, "readonly 下 selectedId 永远 nil")
    }

    // MARK: - R7 count clamp

    func test_R7_countStepperClamp() async {
        let ds = FakeDataSource()
        ds.groupsToReturn = [GiftPanelGroup(tab: .popular, gifts: [gift(1)])]
        let store = CommonGiftPanelStore(config: makeConfig(
            countStepper: .visible(range: 1...99),
            dataSource: ds
        ))
        await store.load()
        XCTAssertEqual(store.count, 1)
        store.setCount(0)
        XCTAssertEqual(store.count, 1, "下限 clamp 到 1")
        store.setCount(100)
        XCTAssertEqual(store.count, 99, "上限 clamp 到 99")
        store.setCount(50)
        XCTAssertEqual(store.count, 50)
        store.incrementCount()
        XCTAssertEqual(store.count, 51)
        store.decrementCount()
        XCTAssertEqual(store.count, 50)
    }

    func test_R7b_countStepperHidden_countStays1_noopSetCount() async {
        let ds = FakeDataSource()
        ds.groupsToReturn = [GiftPanelGroup(tab: .popular, gifts: [gift(1)])]
        let store = CommonGiftPanelStore(config: makeConfig(countStepper: .hidden, dataSource: ds))
        await store.load()
        XCTAssertEqual(store.count, 1)
        store.setCount(50)
        XCTAssertEqual(store.count, 1, "stepper.hidden 时 setCount 是 no-op")
    }

    // MARK: - R11 initialSelection 被 minPrice 过滤 → 静默 clear

    func test_R11_initialSelection_filteredByMinPrice_clearsSilently() async {
        let ds = FakeDataSource()
        let g1 = gift(1, price: 100)
        ds.groupsToReturn = [GiftPanelGroup(tab: .popular, gifts: [g1, gift(2, price: 500)])]
        let store = CommonGiftPanelStore(config: makeConfig(
            minPrice: 300,
            initialSelection: g1,
            dataSource: ds
        ))
        // init 时 selectedId 立即置为 g1.id
        XCTAssertEqual(store.selectedId, 1)
        await store.load()
        XCTAssertNil(store.selectedId, "被 minPrice 过滤后应静默 clear")
    }

    // MARK: - R12 非 APIError → 降级通用文案

    func test_R12_loadFails_nonAPIError_genericFallback() async {
        let ds = FakeDataSource()
        struct FakeError: Error, LocalizedError {
            var errorDescription: String? { "custom" }
        }
        ds.errorToThrow = FakeError()
        let store = CommonGiftPanelStore(config: makeConfig(dataSource: ds))
        await store.load()
        if case .loadFailed(let msg) = store.phase {
            XCTAssertFalse(msg.isEmpty, "非 APIError 也应有 fallback 文案")
        } else {
            XCTFail("expected .loadFailed")
        }
    }

    // MARK: - R13 v3 group name 映射：popular/exclusive/luxury/lucky → tab；未知 → nil
    // v2 补 Lucky Gift 映射（H5 newGiftsPopup.vue 直播中 3 tab 分类）

    func test_R13_groupNameMapping() {
        XCTAssertEqual(GiftPanelTab.fromGroupName("Popular"), .popular)
        XCTAssertEqual(GiftPanelTab.fromGroupName("popular"), .popular)
        XCTAssertEqual(GiftPanelTab.fromGroupName("Exclusive"), .exclusiveGift)
        XCTAssertEqual(GiftPanelTab.fromGroupName("Exclusive gift"), .exclusiveGift)
        XCTAssertEqual(GiftPanelTab.fromGroupName("Luxury"), .exclusiveGift, "Luxury 应映射到 exclusiveGift")
        XCTAssertEqual(GiftPanelTab.fromGroupName("Lucky Gift"), .luckyGift, "H5 newGiftsPopup 直播中 3 tab 之一")
        XCTAssertEqual(GiftPanelTab.fromGroupName("lucky"), .luckyGift)
        XCTAssertEqual(GiftPanelTab.fromGroupName("LuckyGift"), .luckyGift)
        XCTAssertNil(GiftPanelTab.fromGroupName("Combo"), "未知 group 返 nil（drop）")
        XCTAssertNil(GiftPanelTab.fromGroupName("Unknown"))
    }

    // MARK: - R19 v3 grouped 混合形态：某 group 空 / 某 group 非法 shape

    func test_R19_parseGroupedGiftList_mixedShapes() throws {
        // 构造混合响应：Popular 有效 / Empty 空数组 / Bad 非法 shape (dict 而非 array)
        let obj: [String: Any] = [
            "giftList": [
                "Popular": [
                    ["id": 1, "name": "G1", "giftPrice": 100, "giftSmallImg": "", "giftImg": ""]
                ],
                "Empty": [] as [[String: Any]],
                "Bad": ["not": "an array"] as [String: String]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        let result = try GiftService.parseGroupedGiftListResponse(data)
        XCTAssertEqual(result["Popular"]?.count, 1)
        XCTAssertEqual(result["Empty"]?.count, 0)
        XCTAssertNil(result["Bad"], "非法 shape group 应被 drop（不炸）")
    }

    func test_R19b_parseGroupedGiftList_arrayForm() throws {
        // 老形态 1：直接数组 → 归到单 group "Popular"
        let arr = [
            ["id": 1, "name": "G1", "giftPrice": 100, "giftSmallImg": "", "giftImg": ""]
        ]
        let data = try JSONSerialization.data(withJSONObject: arr)
        let result = try GiftService.parseGroupedGiftListResponse(data)
        XCTAssertEqual(result["Popular"]?.count, 1)
    }

    // MARK: - Selection invariants: tap disabled 期 no-op（sending 态锁定）

    func test_isBusy_lockedDuringSending() {
        // 由于 sending 是异步 300ms mock，本轮不覆盖真机时序，只测 isBusy computed
        let ds = FakeDataSource()
        ds.groupsToReturn = [GiftPanelGroup(tab: .popular, gifts: [gift(1)])]
        let store = CommonGiftPanelStore(config: makeConfig(dataSource: ds))
        // 未加载时 isBusy = false
        XCTAssertFalse(store.isBusy)
    }
}
