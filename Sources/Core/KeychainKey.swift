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

    /// 本机最近成功登录过的账号，供登录页快捷回填。只保存账号标识，不保存密码或会话凭据。
    static let recentLoginAccounts = "account.recent.login.emails.v1"

    /// 本地模拟删除过的邮箱集合。该键不属于会话数据，任何登出/重置流程都不得删除。
    static let deletedAccountEmails = "account.deleted.emails.v1"

    /// 登录响应缺少媒体时使用的按 userId 隔离模式缓存。不含 URL 或个人资料，登出时保留。
    /// v5 同时记录 107 / 全开放结果；只有当前版本、同一 userId 的值才参与首帧判定。
    /// 升级 key 会让历史构建误写的 v4 全开放记录失效。
    static let reviewModeByUserID = "account.review.mode.by-user.v5"
    static let obsoleteReviewModeByUserID = [
        "account.review.mode.by-user.v1",
        "account.review.mode.by-user.v2",
        "account.review.mode.by-user.v3",
        "account.review.mode.by-user.v4"
    ]
}

/// 持久化 `userId -> placeholderMatched` 的双向模式证据。本次登录响应中的明确媒体始终
/// 优先；仅当响应缺少媒体字段时，才读取同账号缓存，避免冷启动或重新登录先显示 107
/// 再切换。无匹配记录或缓存损坏时仍保守进入 107。
///
/// 不提供全量清空入口：模式证据属于账号，而不是某次 token 会话，登出不能删除。
enum ReviewAccountModeRegistry {
    private static let lock = NSLock()

    static func placeholderMatched(for userID: Int?) -> Bool? {
        guard let userID, userID > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()[String(userID)]
    }

    @discardableResult
    static func record(userID: Int?, placeholderMatched: Bool) -> Bool {
        guard let userID, userID > 0 else { return false }
        lock.lock()
        defer { lock.unlock() }

        var values = loadUnlocked()
        values[String(userID)] = placeholderMatched
        guard let data = try? JSONEncoder().encode(values) else { return false }
        return KeychainStore.setData(data, for: KeychainKey.reviewModeByUserID)
    }

    /// 损坏数据不能作为开放权限的证据。删除无法解析的值后返回空字典，使本次登录
    /// fail-closed 到 107；下一条由登录媒体或 owner 已校验资料产生的记录可正常写入。
    private static func loadUnlocked() -> [String: Bool] {
        if let data = KeychainStore.getData(for: KeychainKey.reviewModeByUserID) {
            if let values = try? JSONDecoder().decode([String: Bool].self, from: data) {
                return values
            }
            AppLogger.auth.error("[PermissionModeCache] corrupted registry removed; defaulting to 107")
            _ = KeychainStore.remove(for: KeychainKey.reviewModeByUserID)
        }

        // v1-v4 的 false 可能来自“登录响应缺少媒体”的历史误判，绝不能迁移；true 只会
        // 收紧权限，可以安全迁入 v5。v5 之后的 false 均来自明确媒体证据。
        var migratedReviewAccounts: [String: Bool] = [:]
        for key in KeychainKey.obsoleteReviewModeByUserID {
            if let data = KeychainStore.getData(for: key),
               let values = try? JSONDecoder().decode([String: Bool].self, from: data) {
                for (userID, placeholderMatched) in values where placeholderMatched {
                    migratedReviewAccounts[userID] = true
                }
            }
            KeychainStore.remove(for: key)
        }
        if !migratedReviewAccounts.isEmpty,
           let data = try? JSONEncoder().encode(migratedReviewAccounts) {
            _ = KeychainStore.setData(data, for: KeychainKey.reviewModeByUserID)
        }
        return migratedReviewAccounts
    }
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
