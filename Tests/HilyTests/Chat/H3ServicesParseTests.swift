import XCTest

/// H-3 Step 1a-4：TranslateService.parseTranslatedText + CheckPrivateInfoHTTPService.parseResponse
/// + ChatTypeResolver + CallCooldownGuard 4 组纯静态函数单测。
///
/// 覆盖 spec §4.7 翻译 / §4.2 私密 lockStatus 双兼容 / §2.7 chatType 兜底 / §2.8 5s cooldown。
final class H3ServicesParseTests: XCTestCase {

    // MARK: - TranslateService.parseTranslatedText（§4.7 F-21）

    /// 微软返回标准 `[{translations: [{text, to}]}]` → 取 res[0].translations[0].text
    func testTranslate_ParseValidResponse() throws {
        let json = #"[{"translations": [{"text": "你好", "to": "zh"}]}]"#
        let text = try MicrosoftTranslateService.parseTranslatedText(from: json.data(using: .utf8)!)
        XCTAssertEqual(text, "你好")
    }

    /// 多语翻译响应只取第一项（对齐 H5 `c-translate.vue` `res[0].translations[0].text`）
    func testTranslate_ParseMultiTranslationsTakesFirst() throws {
        let json = #"[{"translations": [{"text": "你好", "to": "zh"}, {"text": "Bonjour", "to": "fr"}]}]"#
        let text = try MicrosoftTranslateService.parseTranslatedText(from: json.data(using: .utf8)!)
        XCTAssertEqual(text, "你好")
    }

    func testTranslate_ParseEmptyArray_Throws() {
        let json = "[]"
        XCTAssertThrowsError(try MicrosoftTranslateService.parseTranslatedText(from: json.data(using: .utf8)!)) { error in
            XCTAssertEqual(error as? TranslateServiceError, .invalidResponse)
        }
    }

    func testTranslate_ParseMissingTranslations_Throws() {
        let json = #"[{"detectedLanguage": {"language": "en", "score": 0.99}}]"#
        XCTAssertThrowsError(try MicrosoftTranslateService.parseTranslatedText(from: json.data(using: .utf8)!))
    }

    func testTranslate_ParseEmptyTranslationsArray_Throws() {
        let json = #"[{"translations": []}]"#
        XCTAssertThrowsError(try MicrosoftTranslateService.parseTranslatedText(from: json.data(using: .utf8)!))
    }

    func testTranslate_ParseMissingTextField_Throws() {
        let json = #"[{"translations": [{"to": "zh"}]}]"#
        XCTAssertThrowsError(try MicrosoftTranslateService.parseTranslatedText(from: json.data(using: .utf8)!))
    }

    func testTranslate_ParseInvalidJSON_Throws() {
        let data = "not-json".data(using: .utf8)!
        XCTAssertThrowsError(try MicrosoftTranslateService.parseTranslatedText(from: data))
    }

    // MARK: - CheckPrivateInfoHTTPService.parseResponse（S3 spike 双兼容）

    /// list 响应：`[{privateId: String, lockStatus: 0}]` → dict
    func testCheckPrivate_ParseListResponse_StringId() throws {
        let json = #"[{"privateId": "abc", "lockStatus": 0}, {"privateId": "xyz", "lockStatus": 1}]"#
        let result = try CheckPrivateInfoHTTPService.parseResponse(json.data(using: .utf8)!)
        XCTAssertEqual(result["abc"], .locked)
        XCTAssertEqual(result["xyz"], .unlocked)
        XCTAssertEqual(result.count, 2)
    }

    /// list 响应：privateId 是 Int → 兼容转 String（rule ios-decode-userid-compat）
    func testCheckPrivate_ParseListResponse_IntId() throws {
        let json = #"[{"privateId": 12345, "lockStatus": 1}]"#
        let result = try CheckPrivateInfoHTTPService.parseResponse(json.data(using: .utf8)!)
        XCTAssertEqual(result["12345"], .unlocked)
    }

    /// dict 响应：`{[privateId]: lockStatus}` 直接映射
    func testCheckPrivate_ParseDictResponse() throws {
        let json = #"{"abc": 0, "xyz": 1}"#
        let result = try CheckPrivateInfoHTTPService.parseResponse(json.data(using: .utf8)!)
        XCTAssertEqual(result["abc"], .locked)
        XCTAssertEqual(result["xyz"], .unlocked)
    }

    /// spec §R-7：lockStatus 缺失 → .unknown（不 dead-state）
    func testCheckPrivate_ParseMissingLockStatus_UnknownValue() throws {
        let json = #"[{"privateId": "abc"}]"#
        let result = try CheckPrivateInfoHTTPService.parseResponse(json.data(using: .utf8)!)
        XCTAssertEqual(result["abc"], .unknown)
    }

    /// spec §R-6：空 list / 空 dict → 空 dict（Store 层 merge 时不覆盖现有 status）
    func testCheckPrivate_ParseEmptyList_ReturnsEmpty() throws {
        let json = "[]"
        let result = try CheckPrivateInfoHTTPService.parseResponse(json.data(using: .utf8)!)
        XCTAssertTrue(result.isEmpty)
    }

    func testCheckPrivate_ParseEmptyDict_ReturnsEmpty() throws {
        let json = "{}"
        let result = try CheckPrivateInfoHTTPService.parseResponse(json.data(using: .utf8)!)
        XCTAssertTrue(result.isEmpty)
    }

    /// 响应是 list 但元素非 dict（如 `[42]`） → 落到 fallback throw `.invalidResponse`
    func testCheckPrivate_ParseListOfNonDict_Throws() {
        let json = "[42]"
        XCTAssertThrowsError(try CheckPrivateInfoHTTPService.parseResponse(json.data(using: .utf8)!)) { error in
            XCTAssertEqual(error as? CheckPrivateInfoError, .invalidResponse)
        }
    }

    // MARK: - ChatTypeResolver（§2.7 / S7 spike）

    /// nil ext → .regular（安全兜底）
    func testChatType_NilExt_DefaultsToRegular() {
        XCTAssertEqual(ChatTypeResolver.resolve(from: nil), .regular)
    }

    /// {chatType: "customer"} → .customer
    func testChatType_ExtWithCustomer_ReturnsCustomer() {
        let ext: [String: Any] = ["chatType": "customer"]
        XCTAssertEqual(ChatTypeResolver.resolve(from: ext), .customer)
    }

    /// {chatType: "regular"} → .regular
    func testChatType_ExtWithRegular_ReturnsRegular() {
        let ext: [String: Any] = ["chatType": "regular"]
        XCTAssertEqual(ChatTypeResolver.resolve(from: ext), .regular)
    }

    /// 不含 chatType 字段 → .regular
    func testChatType_ExtWithoutField_DefaultsToRegular() {
        let ext: [String: Any] = ["other": "value"]
        XCTAssertEqual(ChatTypeResolver.resolve(from: ext), .regular)
    }

    /// 未知值 → .regular（安全兜底）
    func testChatType_ExtWithUnknownValue_DefaultsToRegular() {
        let ext: [String: Any] = ["chatType": "unknown-mode"]
        XCTAssertEqual(ChatTypeResolver.resolve(from: ext), .regular)
    }

    // MARK: - CallCooldownGuard（§2.8 / §F-53 / §F-55 / §R-43）

    /// spec §R-43：LiveStore.liveStartTime nil（无历史 live）→ 通过 cooldown（elapsed 极大）
    func testCooldown_NilLiveStartTime_IsCooledDown() {
        XCTAssertTrue(CallCooldownGuard.isCooledDown(liveStartTime: nil))
    }

    /// spec §F-53：baseline + 6s → 通过
    func testCooldown_Over5Seconds_IsCooledDown() {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let now = base.addingTimeInterval(6)
        XCTAssertTrue(CallCooldownGuard.isCooledDown(liveStartTime: base, now: now))
    }

    /// spec §F-55：baseline + 3s → 未过 cooldown
    func testCooldown_Under5Seconds_IsNotCooledDown() {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let now = base.addingTimeInterval(3)
        XCTAssertFalse(CallCooldownGuard.isCooledDown(liveStartTime: base, now: now))
    }

    /// baseline + 5s（边界）→ 通过（`>=` 语义）
    func testCooldown_ExactBoundary_IsCooledDown() {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let now = base.addingTimeInterval(5)
        XCTAssertTrue(CallCooldownGuard.isCooledDown(liveStartTime: base, now: now))
    }
}
