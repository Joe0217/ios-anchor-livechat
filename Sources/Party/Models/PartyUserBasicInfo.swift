import Foundation

/// 派对房用户基础信息（对齐 H5 `apiPartyGetUser({userId})` 返回结构）。
///
/// 用途：进房后拉房主 ownerInfo，取 `headFrameSmallImg` 装饰头像框（H5 `head-frame.vue`）。
/// F/G/H 期若需展示 vip/level/medals 等再补字段——本 struct 只声明**主播端房内当前用到的字段**。
///
/// 字段类型策略（对齐 `ios-decode-userid-compat` rule）：
/// - `userId` 后端 String/Int 混发，用 `PartyValueNormalizer.decodeStringId` 兼容
/// - 其他标量字段全 Optional 容错
struct PartyUserBasicInfo: Codable, Equatable, Sendable {
    let userId: String?
    let nickname: String?
    let avatar: String?
    /// 头像装饰框 URL（可能是 .svga 动画或 .png/.webp 静态图）。对齐 H5 `res.headFrameSmallImg`。
    let headFrameSmallImg: String?
    /// 等级 name（如 "S1"/"SS"）；主播端派对房当前不展示，预留 F 期
    let levelName: String?
    /// vip 状态；主播端派对房当前不展示，预留 F 期
    let vip: Bool?
    let isPlatformAdmin: Bool?
    /// 云信 accid（跨 H5/iOS 一致命名 yxAccid）
    let yxAccid: String?
}
