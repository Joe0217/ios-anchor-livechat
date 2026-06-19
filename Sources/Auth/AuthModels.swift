import Foundation

/// 登录响应（/api/login/v4/login 解密后的 result，取关键字段）。
struct LoginResult: Codable {
    let userId: Int?
    let token: String?
    let loginUuid: String?
    let yxAccid: String?      // 云信 IM 账号
    let imToken: String?      // 云信 IM token
    let userType: Int?        // 2=已审核主播 9=代理
    let nickname: String?
    let icon: String?
}
