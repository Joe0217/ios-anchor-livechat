import XCTest

/// K spec §5.2 R18：BeautyError 分类语义 + L10n key + isRendererFatal 判断。
final class BeautyErrorTests: XCTestCase {

    // MARK: - Equatable

    func test_equatable_sameCase_equal() {
        XCTAssertEqual(BeautyError.authExpired, BeautyError.authExpired)
        XCTAssertEqual(BeautyError.bundleMissing, BeautyError.bundleMissing)
        XCTAssertEqual(BeautyError.genericSetupFailed, BeautyError.genericSetupFailed)
        XCTAssertEqual(BeautyError.setupTimeout(elapsed: 0.6), BeautyError.setupTimeout(elapsed: 0.6))
        XCTAssertEqual(BeautyError.persistenceDecodeFailed(reason: "x"),
                       BeautyError.persistenceDecodeFailed(reason: "x"))
    }

    func test_equatable_differentAssociatedValue_notEqual() {
        XCTAssertNotEqual(BeautyError.setupTimeout(elapsed: 0.6),
                          BeautyError.setupTimeout(elapsed: 0.7))
        XCTAssertNotEqual(BeautyError.persistenceDecodeFailed(reason: "x"),
                          BeautyError.persistenceDecodeFailed(reason: "y"))
    }

    // MARK: - isRendererFatal (对齐 §6.1 #11 触发降级 PassthroughRenderer)

    func test_isRendererFatal_setupCases_true() {
        XCTAssertTrue(BeautyError.authExpired.isRendererFatal)
        XCTAssertTrue(BeautyError.bundleMissing.isRendererFatal)
        XCTAssertTrue(BeautyError.genericSetupFailed.isRendererFatal)
        XCTAssertTrue(BeautyError.setupTimeout(elapsed: 0.6).isRendererFatal)
    }

    func test_isRendererFatal_persistenceCases_false() {
        XCTAssertFalse(BeautyError.persistenceDecodeFailed(reason: "x").isRendererFatal,
                       "persistence 层错误不应触发渲染降级——Store 已兜底")
        XCTAssertFalse(BeautyError.persistenceWriteFailed(reason: "x").isRendererFatal)
    }

    // MARK: - localizationKey（Step 1b UI 层 alert 拼装用）

    func test_localizationKey_uniquePerCase() {
        let allKeys = [
            BeautyError.authExpired.localizationKey,
            BeautyError.bundleMissing.localizationKey,
            BeautyError.genericSetupFailed.localizationKey,
            BeautyError.setupTimeout(elapsed: 0.1).localizationKey,
            BeautyError.persistenceDecodeFailed(reason: "x").localizationKey,
            BeautyError.persistenceWriteFailed(reason: "x").localizationKey,
        ]
        XCTAssertEqual(Set(allKeys).count, allKeys.count, "每个 case 应有唯一 localizationKey")
    }

    func test_localizationKey_prefix() {
        // 所有 key 应以 "beauty.error." 开头（对齐 Localizable.strings 命名空间）
        for key in [
            BeautyError.authExpired.localizationKey,
            BeautyError.bundleMissing.localizationKey,
            BeautyError.genericSetupFailed.localizationKey,
            BeautyError.setupTimeout(elapsed: 0.1).localizationKey,
            BeautyError.persistenceDecodeFailed(reason: "x").localizationKey,
            BeautyError.persistenceWriteFailed(reason: "x").localizationKey,
        ] {
            XCTAssertTrue(key.hasPrefix("beauty.error."), "\(key) 应以 beauty.error. 开头")
        }
    }
}
