#if DEBUG
import Foundation
import Combine

/// DEBUG-only：真机 QA 期间本地注入 fake userType，避免后端配合改数据库账号。
/// Release build 编译不进包体（`#if DEBUG` 门 + 无消费方）。
///
/// 用法：
///   1. Xcode 断点内 lldb 命令：`e DebugPermissionOverride.shared.override = 101`
///   2. `.override = nil` 恢复原生 SessionStore.user.userType
///
/// 详见 spec §Task 16.1（P-plan-用户权限管理系统-*.md）。
final class DebugPermissionOverride {
    static let shared = DebugPermissionOverride()

    /// nil = 用真实 SessionStore.user.userType；非 nil = 强制该值。
    private let subject = CurrentValueSubject<Int?, Never>(nil)

    var override: Int? {
        get { subject.value }
        set { subject.value = newValue }
    }

    var publisher: AnyPublisher<Int?, Never> {
        subject.eraseToAnyPublisher()
    }

    private init() {}
}
#endif
