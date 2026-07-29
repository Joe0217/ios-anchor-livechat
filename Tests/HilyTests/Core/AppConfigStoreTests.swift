import XCTest

/// H-3 Step 1a-1：AppConfigStore + CallAuthLogic 单测。
///
/// 项目 test target 是 logic bundle（把源文件重编一份到自己 module），不 import Hily。
///
/// 覆盖 spec §5.1 F-34/F-36/F-37/F-38 + §5.2 R-9/R-30/R-32/R-33 相关（AppConfigStore 生命周期 + parse 兜底）
/// + Critical-4 派生（CallAuthLogic.canCall 语义 8 分支）。
@MainActor
final class AppConfigStoreTests: XCTestCase {

    // MARK: - AppConfigStore.activate 成功路径

    /// F-34 / F-36：activate 一次拉 4 key + 二次 parse microsoft → 4 字段全填入 + isLoaded=true。
    func testActivateSuccess() async {
        let fetch: ([String]) async throws -> [String: Any] = { keys in
            XCTAssertEqual(keys, AppConfigStore.fetchKeys)
            return [
                "achor_hide_button": "S1S2SS",
                "pay_msg_points": 5,
                "free_msg_points": 1,
                "microsoft_translator_config": #"{"key":"abc-key","area":"westus"}"#,
            ]
        }
        let store = AppConfigStore(fetch: fetch)

        await store.activate()

        XCTAssertEqual(store.achorHideButton, "S1S2SS")
        XCTAssertEqual(store.payMsgPoints, 5)
        XCTAssertEqual(store.freeMsgPoints, 1)
        XCTAssertEqual(store.microsoftTranslatorKey, "abc-key")
        XCTAssertEqual(store.microsoftTranslatorArea, "westus")
        XCTAssertTrue(store.isLoaded)
    }

    /// R-9：pay_msg_points 后端返 String（rule ios-decode-userid-compat 精神：兼容 String/Int/NSNumber）。
    func testActivateIntFromString() async {
        let fetch: ([String]) async throws -> [String: Any] = { _ in
            [
                "pay_msg_points": "10",
                "free_msg_points": NSNumber(value: 3),
            ]
        }
        let store = AppConfigStore(fetch: fetch)
        await store.activate()

        XCTAssertEqual(store.payMsgPoints, 10)
        XCTAssertEqual(store.freeMsgPoints, 3)
    }

    // MARK: - Fallback / 兜底

    /// R-31 兜底路径：fetch 抛错 → fallback microsoft key + isLoaded=true（防 view flash 永久阻塞）。
    func testActivateFetchThrows_ShouldApplyFallback_AndSetIsLoaded() async {
        struct FetchError: Error {}
        let fetch: ([String]) async throws -> [String: Any] = { _ in throw FetchError() }
        let store = AppConfigStore(fetch: fetch)

        await store.activate()

        XCTAssertNil(store.achorHideButton)
        XCTAssertNil(store.payMsgPoints)
        XCTAssertNil(store.freeMsgPoints)
        XCTAssertNil(store.microsoftTranslatorKey)
        XCTAssertNil(store.microsoftTranslatorArea)
        XCTAssertTrue(store.isLoaded, "isLoaded 应设 true 避免 view flash 阻塞")
    }

    /// microsoft_translator_config raw string 非合法 JSON → fallback key/area。
    func testActivateMicrosoftParseInvalidJSON_ShouldFallback() async {
        let fetch: ([String]) async throws -> [String: Any] = { _ in
            [
                "achor_hide_button": "S1",
                "microsoft_translator_config": "not-a-json-string",
            ]
        }
        let store = AppConfigStore(fetch: fetch)
        await store.activate()

        XCTAssertEqual(store.achorHideButton, "S1")
        XCTAssertNil(store.microsoftTranslatorKey)
        XCTAssertNil(store.microsoftTranslatorArea)
        XCTAssertTrue(store.isLoaded)
    }

    /// microsoft_translator_config 合法 JSON 但缺 key 字段 → fallback。
    func testActivateMicrosoftParseMissingField_ShouldFallback() async {
        let fetch: ([String]) async throws -> [String: Any] = { _ in
            ["microsoft_translator_config": #"{"onlyArea":"westus"}"#]
        }
        let store = AppConfigStore(fetch: fetch)
        await store.activate()

        XCTAssertNil(store.microsoftTranslatorKey)
        XCTAssertNil(store.microsoftTranslatorArea)
    }

    // MARK: - clear（logout 挂 session-scoped rule）

    /// F-37：clear 全字段 nil + isLoaded=false（对应 R-33 logout 清除）。
    func testClearResetsAllFields() async {
        let fetch: ([String]) async throws -> [String: Any] = { _ in
            [
                "achor_hide_button": "S1",
                "pay_msg_points": 5,
                "free_msg_points": 1,
                "microsoft_translator_config": #"{"key":"k","area":"a"}"#,
            ]
        }
        let store = AppConfigStore(fetch: fetch)
        await store.activate()
        XCTAssertTrue(store.isLoaded)

        store.clear()

        XCTAssertNil(store.achorHideButton)
        XCTAssertNil(store.payMsgPoints)
        XCTAssertNil(store.freeMsgPoints)
        XCTAssertNil(store.microsoftTranslatorKey)
        XCTAssertNil(store.microsoftTranslatorArea)
        XCTAssertFalse(store.isLoaded)
    }

    /// R-33 换账号：logout clear + 再 login 时 activate 覆盖旧账号残留。
    func testClearThenActivateOverwrites() async {
        var currentAuth = "S1"
        let fetch: ([String]) async throws -> [String: Any] = { _ in
            ["achor_hide_button": currentAuth]
        }
        let store = AppConfigStore(fetch: fetch)

        await store.activate()
        XCTAssertEqual(store.achorHideButton, "S1")

        store.clear()
        XCTAssertNil(store.achorHideButton)

        currentAuth = "SS"   // 模拟切换到 B 账号
        await store.activate()
        XCTAssertEqual(store.achorHideButton, "SS", "clear 后再 activate 应覆盖新值，不残留 A 账号")
    }

    // MARK: - intFromAny helper

    func testIntFromAny_Int() {
        XCTAssertEqual(AppConfigStore.intFromAny(5), 5)
    }

    func testIntFromAny_String() {
        XCTAssertEqual(AppConfigStore.intFromAny("10"), 10)
    }

    func testIntFromAny_NSNumber() {
        XCTAssertEqual(AppConfigStore.intFromAny(NSNumber(value: 42)), 42)
    }

    func testIntFromAny_NilOrInvalid() {
        XCTAssertNil(AppConfigStore.intFromAny(nil))
        XCTAssertNil(AppConfigStore.intFromAny("abc"))
        XCTAssertNil(AppConfigStore.intFromAny([1, 2]))
    }

    // MARK: - CallAuthLogic.canCall（对应 spec F-32/F-33/F-35 + R-29/R-30 + Critical-4）

    /// F-33 / F-35：achorHideButton 含 levelName 子串 + isLoaded → true。
    func testCanCall_HitsLevelName_ReturnsTrue() {
        XCTAssertTrue(CallAuthLogic.canCall(
            achorHideButton: "S1S2SS", levelName: "S1", isLoaded: true
        ))
        XCTAssertTrue(CallAuthLogic.canCall(
            achorHideButton: "S1,SS,NEW", levelName: "SS", isLoaded: true
        ))
    }

    /// F-33：不含 → false。
    func testCanCall_MissLevelName_ReturnsFalse() {
        XCTAssertFalse(CallAuthLogic.canCall(
            achorHideButton: "SS,A", levelName: "S1", isLoaded: true
        ))
    }

    /// R-30 竞态兜底：isLoaded=false 时无论其他参数如何 → false（防 flash 允许）。
    func testCanCall_NotLoaded_ReturnsFalse() {
        XCTAssertFalse(CallAuthLogic.canCall(
            achorHideButton: "S1", levelName: "S1", isLoaded: false
        ))
    }

    /// achorHideButton nil/empty → false。
    func testCanCall_NilOrEmptyAchorHideButton_ReturnsFalse() {
        XCTAssertFalse(CallAuthLogic.canCall(
            achorHideButton: nil, levelName: "S1", isLoaded: true
        ))
        XCTAssertFalse(CallAuthLogic.canCall(
            achorHideButton: "", levelName: "S1", isLoaded: true
        ))
    }

    /// R-29：levelName nil/empty → false。
    func testCanCall_NilOrEmptyLevelName_ReturnsFalse() {
        XCTAssertFalse(CallAuthLogic.canCall(
            achorHideButton: "S1", levelName: nil, isLoaded: true
        ))
        XCTAssertFalse(CallAuthLogic.canCall(
            achorHideButton: "S1", levelName: "", isLoaded: true
        ))
    }

    /// R-30 quirk：H5 `String.includes("")` 是 true —— **但被上游 `levelName != nil && !empty` 提前守卫住**，
    /// 所以不会真触发到 `.contains("")` 语义。此测试确认守卫先于 quirk 生效。
    func testCanCall_EmptyLevelName_DoesNotHitContainsEmpty() {
        // levelName="" 被守卫 → false（未触发 achorHideButton.contains("") = true 的 quirk）
        XCTAssertFalse(CallAuthLogic.canCall(
            achorHideButton: "S1", levelName: "", isLoaded: true
        ))
    }
}
