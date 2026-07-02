import Foundation

/// K spec §5.2 R1/R2/R6-b/R18：BeautySettingsPersistence Fakes 注入。
///
/// 用法：
/// ```
/// let fake = FakeBeautyPersistence()
/// fake.loadResult = .success(customSettings)  // 或 .failure(BeautyError.persistenceDecodeFailed(...))
/// fake.saveError = BeautyError.persistenceWriteFailed(...)
/// let store = BeautySettingsStore(persistence: fake)
/// ```
final class FakeBeautyPersistence: BeautySettingsPersistence {
    /// load 返回值：默认 success(nil)（首次进入语义）
    var loadResult: Result<BeautySettings?, Error> = .success(nil)
    /// save 抛错开关：设置后所有 save 调用都会抛此错误
    var saveError: Error?
    /// 记录所有成功保存的 settings
    private(set) var savedSettings: [BeautySettings] = []
    private(set) var loadCallCount = 0
    private(set) var saveCallCount = 0
    private(set) var clearCallCount = 0

    func load() throws -> BeautySettings? {
        loadCallCount += 1
        switch loadResult {
        case .success(let s): return s
        case .failure(let e): throw e
        }
    }

    func save(_ settings: BeautySettings) throws {
        saveCallCount += 1
        if let e = saveError { throw e }
        savedSettings.append(settings)
    }

    func clear() {
        clearCallCount += 1
        savedSettings.removeAll()
    }
}
