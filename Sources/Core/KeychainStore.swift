import Foundation
import Security

/// 通用 Keychain 持久化封装，供登录凭据等敏感字段使用。
///
/// 安全策略：
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：首次解锁后可读、本设备绑定、不进 iCloud Keychain、不进 iTunes 加密备份
/// - `kSecAttrSynchronizable = false`：禁 iCloud 同步
/// - service = bundleId，account = 调用方 key；同 bundleId 内 key 唯一
///
/// 接口同步设计：底层 SecItem* 是同步调用，调用方继续按 UserDefaults 风格使用即可；
/// 写频次低（登录/登出），主线程同步写无性能压力。
enum KeychainStore {
    enum KeychainError: Error {
        case status(OSStatus)
    }

    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.anchor.livechat"
    }

    @discardableResult
    static func setData(_ data: Data, for key: String) -> Bool {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
        ]
        // 先尝试更新
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound { return false }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func getData(for key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func setString(_ s: String, for key: String) -> Bool {
        guard let data = s.data(using: .utf8) else { return false }
        return setData(data, for: key)
    }

    static func getString(for key: String) -> String? {
        guard let data = getData(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func remove(for key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
