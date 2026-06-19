import Foundation
import NIMSDK

/// 云信 NIM 长连接保活，专门用来上报"主播在线"。
///
/// 后端（与 H5 / 用户端共用）通过云信 presence 判断主播是否 online——这是用户端列表/搜索
/// 看到"主播在线"的唯一来源。iOS 主播登录后必须立刻建 NIM 长连接并保持，否则即便登录成功，
/// 用户端 `apiBatchQueryYxStatByUid` / NIM `subscribeOnlineStatusEvents` 都查不到本端在线。
///
/// 与 NIMChatroomManager 解耦：聊天室登录态会复用本类已建好的连接（`loginManager.isLogined()`
/// 命中后直接进房，不重复 login）。
@MainActor
final class NIMOnlineKeeper {
    static let shared = NIMOnlineKeeper()

    @Published private(set) var isLogined: Bool = false

    private init() {}

    /// 登录后调用。重复调用安全：已登录直接返回。
    func start(account: String, token: String) {
        NIMChatroomManager.setupOnce()  // 复用：确保 SDK 已 register(appKey:)
        if NIMSDK.shared().loginManager.isLogined() {
            print("🟢 [NIMOnline] 已登录，跳过")
            isLogined = true
            return
        }
        print("🟢 [NIMOnline] 开始登录 account=\(account) tokenLen=\(token.count)")
        NIMSDK.shared().loginManager.login(account, token: token) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error = error {
                    let code = (error as NSError).code
                    print("🔴 [NIMOnline] 登录失败 code=\(code) err=\(error.localizedDescription)")
                    self.isLogined = false
                } else {
                    self.isLogined = true
                    print("✅ [NIMOnline] 登录成功 — 主播在线态已上报")
                }
            }
        }
    }

    /// 登出时调用。
    func stop() {
        guard NIMSDK.shared().loginManager.isLogined() else {
            isLogined = false
            return
        }
        NIMSDK.shared().loginManager.logout { error in
            DispatchQueue.main.async {
                if let error = error {
                    print("⚠️ [NIMOnline] logout 失败: \(error.localizedDescription)")
                } else {
                    print("🟢 [NIMOnline] 已 logout")
                }
            }
        }
        isLogined = false
    }
}
