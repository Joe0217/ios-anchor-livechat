import Foundation

/// 登录响应（/api/login/v4/login 解密后的 result，取关键字段）。
///
/// H5 蓝本 `loginSuccess(res)` 直接用登录响应本身设 mineInfo（`src/stores/modules/user.js:74-131`），
/// 登录不再依赖 profile 接口拉取——iOS 对齐同款语义，将审核相关字段从登录响应直接读取。
///
/// ⚠️ 2026-07-17 tap-fix 真根因:后端登录响应对未审核账号可能只返 `type`(审核结果类型),不返 `userType`
/// → iOS auto synthesized CodingKeys 只匹配 `userType` key → 解得 nil → `RootView.isRestricted` guard-let
/// 兜底 false → 用户被路由到 MainTabView(而非 RestrictedTabView),tap 无反应 + view log 一条不 fire。
///
/// **修复**:手写 `init(from:)` 让 `userType` **双 key 兜底**(`userType` → fallback `type`),同款 fallback
/// 也覆盖到 `type` 字段。真机首次登录后打 log 抓取真实字段名,若与 userType/type 都不匹配再补 alias。
struct LoginResult: Codable {
    let userId: Int?
    let token: String?
    let loginUuid: String?
    let yxAccid: String?      // 云信 IM 账号
    let imToken: String?      // 云信 IM token
    let userType: Int?        // 2=已审核主播 9=代理，其他=未审核/审核中/被拒
    let nickname: String?
    let icon: String?

    // MARK: - 审核态字段（受限首屏 banner 派生源；对齐 H5 newsRestricted/mineRestricted）

    /// 账号状态：0=封禁 / 1=正常（正常态下再由 onReview/type 细分审核中/通过/拒绝）
    let valid: Int?
    /// 审核中标记（true=资料审核中）；对齐 H5 `mineInfo.onReview`
    let onReview: Bool?
    /// 永久封禁（valid=0 时判定）；对齐 H5 `mineInfo.banAlways`
    let banAlways: Bool?
    /// 临时封禁时长（小时数）；对齐 H5 `mineInfo.bannedSubType`
    let bannedSubType: Int?
    /// 审核结果类型（type=2 通过 / type=9 代理 / 其他=拒绝或未审核）；对齐 H5 `mineInfo.type`
    /// 与 userType 语义相近但独立字段——H5 restricted 页用 type 判"审核通过 kill-app-restart"
    let type: Int?

    /// Memberwise init 保留供 test/preview 构造
    init(userId: Int?, token: String?, loginUuid: String?, yxAccid: String?, imToken: String?,
         userType: Int?, nickname: String?, icon: String?,
         valid: Int? = nil, onReview: Bool? = nil, banAlways: Bool? = nil,
         bannedSubType: Int? = nil, type: Int? = nil) {
        self.userId = userId
        self.token = token
        self.loginUuid = loginUuid
        self.yxAccid = yxAccid
        self.imToken = imToken
        self.userType = userType
        self.nickname = nickname
        self.icon = icon
        self.valid = valid
        self.onReview = onReview
        self.banAlways = banAlways
        self.bannedSubType = bannedSubType
        self.type = type
    }

    /// 2026-07-17 tap-fix v4:手写 init(from:) 让 `userType` 与 `type` **互为兜底**——后端对未审核账号可能只
    /// 返其中一个 key。`RootView.isRestricted` 依赖 `userType != 2 && != 9`,任一 key 拿到值即可正确分流。
    ///
    /// 同款 flexible 兜底也扩到 audit 字段(valid/onReview/banAlways/bannedSubType) —— 用 `decodeFlexibleInt`
    /// 支持 String/Int 混发(对齐 `ios-decode-userid-compat.md` rule)。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.userId = try c.decodeIfPresent(Int.self, forKey: .userId)
        self.token = try c.decodeIfPresent(String.self, forKey: .token)
        self.loginUuid = try c.decodeIfPresent(String.self, forKey: .loginUuid)
        self.yxAccid = try c.decodeIfPresent(String.self, forKey: .yxAccid)
        self.imToken = try c.decodeIfPresent(String.self, forKey: .imToken)
        self.nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon)

        // userType / type 双 key 互为兜底 —— 后端可能只返一个(H5 mineInfo 两者都用,H5 App.vue 用 userType 分流,
        // H5 mineRestricted 用 type 判 kill-app-restart)。iOS RootView.isRestricted 读 userType,统一 alias。
        let rawUserType = c.decodeFlexibleInt(forKey: .userType)
        let rawType = c.decodeFlexibleInt(forKey: .type)
        self.userType = rawUserType ?? rawType
        self.type = rawType ?? rawUserType

        // 审核态字段 flexible decode(Bool/0/1/String 兼容)
        self.valid = c.decodeFlexibleInt(forKey: .valid)
        self.onReview = c.decodeFlexibleBool(forKey: .onReview)
        self.banAlways = c.decodeFlexibleBool(forKey: .banAlways)
        self.bannedSubType = c.decodeFlexibleInt(forKey: .bannedSubType)
    }
}
