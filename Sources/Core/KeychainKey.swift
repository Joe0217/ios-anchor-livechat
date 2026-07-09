// Sources/Core/KeychainKey.swift
import Foundation

/// Keychain key 常量 namespace。
///
/// 跨类型（SessionStore ↔ RegisterStore）共享的 Keychain key 集中放这里，
/// 避免 private let scattered 在各类内导致跨类型引用编译不过（A-2 spec v3 NEW-1）。
enum KeychainKey {
    /// A-2 resubmit 场景：login → register 短期传密（Submit 成功清 + logout 清）
    static let pendingRegisterPassword = "session.pending.password.v1"
}
