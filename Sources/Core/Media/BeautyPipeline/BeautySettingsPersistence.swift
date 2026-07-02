import Foundation

/// 美颜参数持久化协议（K spec §4.6 + §9 Step 1c）。
///
/// 抽象出 protocol 便于 Store 单测注入 Fakes（Step 1c R1/R2/R6-b/R18 反向 case）。
/// 真实现：`UserDefaultsBeautyPersistence`（v1 key = `beauty.settings.v1`）。
///
/// - **失败契约**：读盘失败 (decode) → 抛 `BeautyError.persistenceDecodeFailed`，Store 兜底默认档；
///   写盘失败 (disk full 等) → 抛 `BeautyError.persistenceWriteFailed`，Store 记录并可重试。
protocol BeautySettingsPersistence: AnyObject {
    /// 读盘。返回 nil = key 不存在（首次进入）；抛错 = 数据损坏
    func load() throws -> BeautySettings?

    /// 写盘。encode 或写入失败抛错
    func save(_ settings: BeautySettings) throws

    /// 清空持久化（**仅测试用**，生产禁用；`恢复默认` 不清盘，只写 default）
    func clear()
}

// MARK: - UserDefaults 真实现

/// K spec §4.6：UserDefaults JSON key = `beauty.settings.v1`。
///
/// 版本号预留 v2 迁移路径：未来加字段用 v1 key + BeautySettings 结构 decodeIfPresent 兜底默认，
/// 不写 v2 key（避免碎片）。
final class UserDefaultsBeautyPersistence: BeautySettingsPersistence {
    /// v1 存储 key（v2 迁移时用 keyDecodingStrategy + fallback default，不换 key）
    static let key = "beauty.settings.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> BeautySettings? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        do {
            return try JSONDecoder().decode(BeautySettings.self, from: data)
        } catch {
            throw BeautyError.persistenceDecodeFailed(reason: String(describing: error))
        }
    }

    func save(_ settings: BeautySettings) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(settings)
        } catch {
            throw BeautyError.persistenceWriteFailed(reason: "encode: \(error)")
        }
        defaults.set(data, forKey: Self.key)
        // UserDefaults 无同步写盘失败信号（内部 async），此处仅记录 set 已入 in-memory；
        // 真 disk full 场景 iOS 系统层面通常直接杀 App，业务层无从捕获
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

// MARK: - Preview / Test 内存实现

/// SwiftUI Preview / 快速集成测试用的 in-memory 实现（生产不用）。
/// **不入 HilyTests target**（tests 用 FakeBeautyPersistence 有更细控制点）。
final class InMemoryBeautyPersistence: BeautySettingsPersistence {
    private var storage: BeautySettings?

    init(initial: BeautySettings? = nil) {
        self.storage = initial
    }

    func load() throws -> BeautySettings? { storage }
    func save(_ settings: BeautySettings) throws { storage = settings }
    func clear() { storage = nil }
}
