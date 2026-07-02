import XCTest

/// K spec §5.2 R1/R4/R8-b/R19：BeautySettings Codable + defaults + filterName 白名单。
///
/// 覆盖：
/// - defaults 全 26+ 字段的 UI initValue
/// - Codable decode 完整 JSON / 空 JSON / 部分 JSON（前向兼容）/ 非法 filterName（R8-b）
/// - Codable encode round-trip
/// - FilterKey 白名单 11 项 + isSupported 边界
final class BeautySettingsTests: XCTestCase {

    // MARK: - Defaults 全字段（K spec §4.2/4.3 表 UI initValue）
    func testDefaults_globalFields() {
        let d = BeautySettings.defaults
        XCTAssertTrue(d.enabled)
        XCTAssertEqual(d.blurType, 2)
    }

    func testDefaults_skinFields() {
        let d = BeautySettings.defaults
        XCTAssertEqual(d.blur, 55)
        XCTAssertEqual(d.whiten, 40)       // R19 首帧契约
        XCTAssertEqual(d.red, 30)
        XCTAssertEqual(d.clarity, 0)
        XCTAssertEqual(d.sharpen, 60)
        XCTAssertEqual(d.faceThreed, 40)
        XCTAssertEqual(d.eyeBright, 30)
        XCTAssertEqual(d.toothWhiten, 0)
        XCTAssertEqual(d.removePouch, 40)
        XCTAssertEqual(d.removeNasolabialFolds, 80)
    }

    func testDefaults_shapeFields() {
        let d = BeautySettings.defaults
        XCTAssertEqual(d.cheekV, 50)
        XCTAssertEqual(d.cheekNarrow, 0)
        XCTAssertEqual(d.cheekShort, 0)
        XCTAssertEqual(d.cheekSmall, 0)
        XCTAssertEqual(d.intensityCheekbones, 0)
        XCTAssertEqual(d.intensityLowerJaw, 10)
        XCTAssertEqual(d.eyeEnlarging, 40)
        XCTAssertEqual(d.intensityEyeCircle, 0)
        XCTAssertEqual(d.intensityChin, 0)     // type2，UI=0 → 中性
        XCTAssertEqual(d.intensityForehead, 0)
        XCTAssertEqual(d.intensityNose, 50)
        XCTAssertEqual(d.intensityMouth, 0)
        XCTAssertEqual(d.intensityLipThick, 0)
        XCTAssertEqual(d.intensityCanthus, 0)
        XCTAssertEqual(d.intensityEyeSpace, 0)
    }

    func testDefaults_filterFields() {
        let d = BeautySettings.defaults
        XCTAssertEqual(d.filterName, "origin")
        XCTAssertEqual(d.filterLevel, 50)
    }

    // MARK: - Codable decode round-trip
    func testEncodeDecode_roundTrip() throws {
        var s = BeautySettings()
        s.enabled = false
        s.blur = 88.5
        s.whiten = 12.3
        s.filterName = "mitao1"
        s.filterLevel = 33
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(BeautySettings.self, from: data)
        XCTAssertEqual(decoded, s)
    }

    // MARK: - R1：Codable decode 空 JSON `{}` → 全 defaults（Store 兜底路径）
    func testDecode_emptyJSON_fallbackDefaults() throws {
        let data = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(BeautySettings.self, from: data)
        XCTAssertEqual(decoded, BeautySettings.defaults)
    }

    // MARK: - 前向兼容：v1→v2 加字段场景（红队 C2）
    func testDecode_partialJSON_missingFieldsUseDefaults() throws {
        // 模拟未来 v2 JSON 里只有部分字段（其余用默认）
        let json = #"{"blur":77,"whiten":22}"#
        let decoded = try JSONDecoder().decode(BeautySettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.blur, 77)
        XCTAssertEqual(decoded.whiten, 22)
        // 未出现在 JSON 的字段应回到默认
        XCTAssertEqual(decoded.red, 30)
        XCTAssertEqual(decoded.sharpen, 60)
        XCTAssertEqual(decoded.filterName, "origin")
        XCTAssertTrue(decoded.enabled)
    }

    func testDecode_extraUnknownField_ignored() throws {
        // 模拟未来 v2 加字段被 v1 decoder 读到 → 应忽略未知
        let json = #"{"blur":77,"unknownFutureField":"anything"}"#
        let decoded = try JSONDecoder().decode(BeautySettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.blur, 77)
        XCTAssertEqual(decoded, {
            var s = BeautySettings()
            s.blur = 77
            return s
        }())
    }

    // MARK: - R8-b：filterName 白名单校验（红队 C1）
    func testDecode_invalidFilterName_fallbackOrigin() throws {
        let json = #"{"filterName":"unknownFilter_XYZ"}"#
        let decoded = try JSONDecoder().decode(BeautySettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.filterName, "origin", "非法 filterName 应 fallback origin")
    }

    func testDecode_validFilterName_kept() throws {
        for filter in FilterKey.whitelist {
            let json = #"{"filterName":"\#(filter)"}"#
            let decoded = try JSONDecoder().decode(BeautySettings.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.filterName, filter, "白名单 \(filter) 应保留")
        }
    }

    func testDecode_emptyStringFilterName_fallbackOrigin() throws {
        let json = #"{"filterName":""}"#
        let decoded = try JSONDecoder().decode(BeautySettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.filterName, "origin", "空字符串 filterName 应 fallback origin")
    }

    // MARK: - FilterKey 白名单
    func testFilterKey_whitelistCount() {
        XCTAssertEqual(FilterKey.whitelist.count, 11)
        XCTAssertEqual(FilterKey.whitelist.first, "origin")
    }

    func testFilterKey_isSupported_positive() {
        XCTAssertTrue(FilterKey.isSupported("origin"))
        XCTAssertTrue(FilterKey.isSupported("ziran1"))
        XCTAssertTrue(FilterKey.isSupported("heibai1"))
    }

    func testFilterKey_isSupported_negative() {
        XCTAssertFalse(FilterKey.isSupported(""))
        XCTAssertFalse(FilterKey.isSupported("ziran2"))  // 相芯有此变体但本期不暴露
        XCTAssertFalse(FilterKey.isSupported("evil_filter"))
        XCTAssertFalse(FilterKey.isSupported("ORIGIN"))  // 大小写敏感
    }

    // MARK: - Equatable & Sendable 语义
    func testEquatable_defaultsSelfEqual() {
        XCTAssertEqual(BeautySettings.defaults, BeautySettings.defaults)
    }

    func testEquatable_mutatedNotEqual() {
        var a = BeautySettings.defaults
        a.blur = 99
        XCTAssertNotEqual(a, BeautySettings.defaults)
    }

    // MARK: - R4 UI 极限（0/100/-50/50）Codable 保真
    func testCodable_extremeValues() throws {
        var s = BeautySettings()
        s.blur = 0
        s.whiten = 100
        s.intensityChin = -50    // type2 min
        s.intensityForehead = 50 // type2 max
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(BeautySettings.self, from: data)
        XCTAssertEqual(decoded.blur, 0)
        XCTAssertEqual(decoded.whiten, 100)
        XCTAssertEqual(decoded.intensityChin, -50)
        XCTAssertEqual(decoded.intensityForehead, 50)
    }
}
