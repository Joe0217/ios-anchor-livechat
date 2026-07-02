import XCTest

/// K spec §5.2 R1/R2/R4/R9/R9-b：BeautySettingsStore dirty 检测 + flushIfDirty 幂等 + reset 串行。
@MainActor
final class BeautySettingsStoreTests: XCTestCase {

    // MARK: - init 路径

    /// R1: init 时读盘 decode 失败 → 兜底 defaults + 记录 lastPersistenceError
    func test_init_loadDecodeFailure_fallbackDefaults() {
        let fake = FakeBeautyPersistence()
        fake.loadResult = .failure(BeautyError.persistenceDecodeFailed(reason: "corrupt"))
        let store = BeautySettingsStore(persistence: fake)
        XCTAssertEqual(store.settings, BeautySettings.defaults)
        XCTAssertEqual(store.lastPersistenceError, .persistenceDecodeFailed(reason: "corrupt"))
        XCTAssertFalse(store.isDirty, "decode failure 兜底后视为 clean，不触发 flush 死循环")
    }

    /// 空盘（nil）→ defaults + no error
    func test_init_loadNil_useDefaults() {
        let fake = FakeBeautyPersistence()
        fake.loadResult = .success(nil)
        let store = BeautySettingsStore(persistence: fake)
        XCTAssertEqual(store.settings, BeautySettings.defaults)
        XCTAssertNil(store.lastPersistenceError)
        XCTAssertFalse(store.isDirty)
    }

    /// 有缓存 → 用读到的值 + no error
    func test_init_loadCached_useCached() {
        var cached = BeautySettings.defaults
        cached.blur = 77
        cached.filterName = "mitao1"
        let fake = FakeBeautyPersistence()
        fake.loadResult = .success(cached)
        let store = BeautySettingsStore(persistence: fake)
        XCTAssertEqual(store.settings, cached)
        XCTAssertFalse(store.isDirty, "刚读到的与 lastPersisted 一致，非 dirty")
        XCTAssertNil(store.lastPersistenceError)
    }

    // MARK: - dirty 检测

    func test_mutate_becomesDirty() {
        let store = BeautySettingsStore(persistence: FakeBeautyPersistence())
        XCTAssertFalse(store.isDirty)
        store.mutate { $0.blur = 80 }
        XCTAssertTrue(store.isDirty)
    }

    func test_mutate_sameValue_notDirty() {
        let store = BeautySettingsStore(persistence: FakeBeautyPersistence())
        store.mutate { $0.blur = 55 } // 55 是默认值
        XCTAssertFalse(store.isDirty, "写入默认值不算 dirty")
    }

    // MARK: - R9: flushIfDirty 正常路径

    func test_flush_dirty_savesAndClearDirty() {
        let fake = FakeBeautyPersistence()
        let store = BeautySettingsStore(persistence: fake)
        store.mutate { $0.blur = 90 }
        let did = store.flushIfDirty()
        XCTAssertTrue(did)
        XCTAssertEqual(fake.saveCallCount, 1)
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(fake.savedSettings.last?.blur, 90)
    }

    func test_flush_notDirty_noSave() {
        let fake = FakeBeautyPersistence()
        let store = BeautySettingsStore(persistence: fake)
        let did = store.flushIfDirty()
        XCTAssertFalse(did)
        XCTAssertEqual(fake.saveCallCount, 0)
    }

    /// R9-b: 幂等 —— 连续两次 flush 只 save 一次
    func test_flush_idempotent_secondCallNoOp() {
        let fake = FakeBeautyPersistence()
        let store = BeautySettingsStore(persistence: fake)
        store.mutate { $0.blur = 88 }
        _ = store.flushIfDirty()
        let did2 = store.flushIfDirty()
        XCTAssertFalse(did2, "第二次 flush 无 dirty 应 no-op")
        XCTAssertEqual(fake.saveCallCount, 1)
    }

    // MARK: - R2: save 失败路径

    func test_flush_saveFailed_setsError() {
        let fake = FakeBeautyPersistence()
        fake.saveError = BeautyError.persistenceWriteFailed(reason: "diskFull")
        let store = BeautySettingsStore(persistence: fake)
        store.mutate { $0.blur = 90 }
        let did = store.flushIfDirty()
        XCTAssertFalse(did)
        XCTAssertEqual(store.lastPersistenceError, .persistenceWriteFailed(reason: "diskFull"))
        XCTAssertTrue(store.isDirty, "失败后仍应 dirty，等下次 retry")
    }

    /// save 成功后 lastPersistenceError 清空
    func test_flush_successAfterFailure_clearsError() {
        let fake = FakeBeautyPersistence()
        fake.saveError = BeautyError.persistenceWriteFailed(reason: "diskFull")
        let store = BeautySettingsStore(persistence: fake)
        store.mutate { $0.blur = 90 }
        _ = store.flushIfDirty()
        XCTAssertNotNil(store.lastPersistenceError)
        // 修复问题后重试
        fake.saveError = nil
        _ = store.flushIfDirty()
        XCTAssertNil(store.lastPersistenceError)
    }

    // MARK: - R9-b: reset 恢复默认 + 立即 flush

    func test_reset_toDefaults_andImmediateSave() {
        let fake = FakeBeautyPersistence()
        var cached = BeautySettings.defaults
        cached.blur = 99
        fake.loadResult = .success(cached)
        let store = BeautySettingsStore(persistence: fake)
        XCTAssertEqual(store.settings.blur, 99)

        let did = store.reset()
        XCTAssertTrue(did)
        XCTAssertEqual(store.settings, BeautySettings.defaults)
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(fake.saveCallCount, 1)
        XCTAssertEqual(fake.savedSettings.last, BeautySettings.defaults)
    }

    /// reset 已在 defaults 时 no-op
    func test_reset_alreadyDefaults_noSave() {
        let fake = FakeBeautyPersistence()
        let store = BeautySettingsStore(persistence: fake)
        let did = store.reset()
        XCTAssertFalse(did, "已 defaults 时 reset 应 no-op")
        XCTAssertEqual(fake.saveCallCount, 0)
    }

    // MARK: - R4 极值 mutate

    func test_mutate_extremeValues() {
        let store = BeautySettingsStore(persistence: FakeBeautyPersistence())
        store.mutate {
            $0.blur = 0
            $0.whiten = 100
            $0.intensityChin = -50
            $0.intensityForehead = 50
        }
        XCTAssertEqual(store.settings.blur, 0)
        XCTAssertEqual(store.settings.whiten, 100)
        XCTAssertEqual(store.settings.intensityChin, -50)
        XCTAssertEqual(store.settings.intensityForehead, 50)
    }

    // MARK: - 多次 mutate 只需一次 flush
    func test_multipleMutate_thenSingleFlush() {
        let fake = FakeBeautyPersistence()
        let store = BeautySettingsStore(persistence: fake)
        store.mutate { $0.blur = 10 }
        store.mutate { $0.whiten = 20 }
        store.mutate { $0.filterName = "ziran1" }
        _ = store.flushIfDirty()
        XCTAssertEqual(fake.saveCallCount, 1)
        XCTAssertEqual(fake.savedSettings.last?.blur, 10)
        XCTAssertEqual(fake.savedSettings.last?.whiten, 20)
        XCTAssertEqual(fake.savedSettings.last?.filterName, "ziran1")
    }
}
