import SwiftUI

/// A-2 spec §3.2 v3 + plan v2 MINOR-N4：注册流程 NavigationPath 单例持有
///
/// 让 LoginView 顶层唯一 NavigationStack + 4 register view 分派；子 view 通过 EnvironmentObject 拿 path 做 append / pop
@MainActor
final class RegisterPathHolder: ObservableObject {
    static let shared = RegisterPathHolder()
    private init() {}

    @Published var path = NavigationPath()

    /// 注册流程结束（Submit 成功 or 用户主动全 pop 回 login）时清 path
    func reset() { path = NavigationPath() }
}
