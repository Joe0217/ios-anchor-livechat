// Sources/Core/KeychainKey.swift
import Foundation

/// Keychain key 常量 namespace。
///
/// 跨类型（SessionStore ↔ RegisterStore）共享的 Keychain key 集中放这里，
/// 避免 private let scattered 在各类内导致跨类型引用编译不过（A-2 spec v3 NEW-1）。
enum KeychainKey {
    /// A-2 resubmit 场景：login → register 短期传密（Submit 成功清 + logout 清）
    static let pendingRegisterPassword = "session.pending.password.v1"

    /// 当前登录账号邮箱。随普通会话清理，仅用于本地模拟删除流程定位账号。
    static let authenticatedEmail = "session.authenticated.email.v1"

    /// 本地模拟删除过的邮箱集合。该键不属于会话数据，任何登出/重置流程都不得删除。
    static let deletedAccountEmails = "account.deleted.emails.v1"
}

/// 本地模拟删除账号注册表。
///
/// 支持查询、追加，以及恢复注册完成后移除对应邮箱；不提供清空全部记录的接口。
enum DeletedAccountRegistry {
    private static let lock = NSLock()

    static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func contains(_ email: String) -> Bool {
        let normalizedEmail = normalize(email)
        guard !normalizedEmail.isEmpty else { return false }

        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()?.contains(normalizedEmail) == true
    }

    @discardableResult
    static func record(_ email: String) -> Bool {
        let normalizedEmail = normalize(email)
        guard !normalizedEmail.isEmpty else { return false }

        lock.lock()
        defer { lock.unlock() }

        guard var emails = loadUnlocked() else { return false }
        emails.insert(normalizedEmail)
        guard let data = try? JSONEncoder().encode(emails.sorted()) else { return false }
        return KeychainStore.setData(data, for: KeychainKey.deletedAccountEmails)
    }

    /// 仅移除指定邮箱，保留其它已删除账号记录。
    @discardableResult
    static func remove(_ email: String) -> Bool {
        let normalizedEmail = normalize(email)
        guard !normalizedEmail.isEmpty else { return false }

        lock.lock()
        defer { lock.unlock() }

        guard var emails = loadUnlocked() else { return false }
        guard emails.remove(normalizedEmail) != nil else { return true }
        if emails.isEmpty {
            return KeychainStore.remove(for: KeychainKey.deletedAccountEmails)
        }
        guard let data = try? JSONEncoder().encode(emails.sorted()) else { return false }
        return KeychainStore.setData(data, for: KeychainKey.deletedAccountEmails)
    }

    /// nil 表示已有数据损坏；此时拒绝覆盖，避免意外丢失历史删除记录。
    private static func loadUnlocked() -> Set<String>? {
        guard let data = KeychainStore.getData(for: KeychainKey.deletedAccountEmails) else {
            return []
        }
        guard let storedEmails = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return Set(storedEmails.map(normalize).filter { !$0.isEmpty })
    }
}
