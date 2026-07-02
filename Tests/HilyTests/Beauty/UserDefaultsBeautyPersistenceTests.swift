import XCTest

/// K spec §4.6：UserDefaults 真实现 round-trip 集成测试。
///
/// 使用 `UserDefaults(suiteName:)` 隔离测试数据，避免污染 standard defaults。
final class UserDefaultsBeautyPersistenceTests: XCTestCase {

    private var suite: UserDefaults!
    private let suiteName = "com.anchor.livechat.tests.beauty"

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName) // 清空避免上次残留
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        super.tearDown()
    }

    // MARK: - 空盘路径

    func test_load_emptyKey_returnsNil() throws {
        let p = UserDefaultsBeautyPersistence(defaults: suite)
        XCTAssertNil(try p.load(), "首次进入无数据应返回 nil")
    }

    // MARK: - save + load round-trip

    func test_saveThenLoad_roundTrip() throws {
        let p = UserDefaultsBeautyPersistence(defaults: suite)
        var settings = BeautySettings.defaults
        settings.blur = 88
        settings.whiten = 55
        settings.filterName = "mitao1"
        settings.filterLevel = 33
        try p.save(settings)

        let loaded = try p.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded, settings)
    }

    func test_save_thenClear_thenLoadNil() throws {
        let p = UserDefaultsBeautyPersistence(defaults: suite)
        var settings = BeautySettings.defaults
        settings.blur = 88
        try p.save(settings)
        XCTAssertNotNil(try p.load())

        p.clear()
        XCTAssertNil(try p.load(), "clear 后 load 应返回 nil")
    }

    // MARK: - R1: 数据损坏兜底路径

    func test_load_corruptData_throwsDecodeFailure() {
        // 写入非法 JSON
        suite.set(Data("not json".utf8), forKey: UserDefaultsBeautyPersistence.key)
        let p = UserDefaultsBeautyPersistence(defaults: suite)
        XCTAssertThrowsError(try p.load()) { error in
            guard case BeautyError.persistenceDecodeFailed = error else {
                return XCTFail("corrupt data 应抛 persistenceDecodeFailed，实际: \(error)")
            }
        }
    }

    // MARK: - v1→v2 兼容：写入部分字段的 JSON 也能 decode

    func test_load_partialJSON_backwardCompatible() throws {
        // 模拟未来 v2 减字段场景（其实是 v1 缺字段场景）—— Store decoder 应兜底默认
        let partial = #"{"blur":77}"#
        suite.set(Data(partial.utf8), forKey: UserDefaultsBeautyPersistence.key)
        let p = UserDefaultsBeautyPersistence(defaults: suite)
        let loaded = try p.load()
        XCTAssertEqual(loaded?.blur, 77)
        XCTAssertEqual(loaded?.whiten, 40, "缺字段应用默认档兜底")
    }

    // MARK: - v1 Key 稳定性（防未来重构改 key 破坏用户数据）

    func test_key_isV1() {
        XCTAssertEqual(UserDefaultsBeautyPersistence.key, "beauty.settings.v1",
                       "v1 key 是用户数据契约，重构不可轻易改")
    }

    // MARK: - Store 集成：真 UserDefaults + BeautySettingsStore
    @MainActor
    func test_storeIntegration_flushThenReload_persistsAcrossInstances() {
        let p1 = UserDefaultsBeautyPersistence(defaults: suite)
        let store1 = BeautySettingsStore(persistence: p1)
        store1.mutate { $0.blur = 92; $0.filterName = "ziran1" }
        XCTAssertTrue(store1.flushIfDirty())

        // 新 Store 实例读盘，应看到 flush 后的值
        let p2 = UserDefaultsBeautyPersistence(defaults: suite)
        let store2 = BeautySettingsStore(persistence: p2)
        XCTAssertEqual(store2.settings.blur, 92)
        XCTAssertEqual(store2.settings.filterName, "ziran1")
    }
}
