import Foundation

/// 主播详情（/api/anchor/userInfo 的响应模型）。
///
/// 字段全部 Optional：H5 蓝本（docs/plan/iOS重建-功能梳理-20260616/modules/09-账号设置与基建.md §243）
/// 里未明确接口出参清单，只能列出「设计上需要的字段」并由实际响应回填。
/// 拿到真机响应后，缺失字段补 nil 不抛错；多出字段忽略；字段名/类型不符再迭代调整。
///
/// 数值字段统一 Int? + Codable，避免后端混发字符串/数字时崩溃的兜底由 ProfileViewModel 通过
/// `getAnchorInfoRaw()` 的字典回退（`intValue(_:)`/`stringValue(_:)`）处理。
struct AnchorInfo: Codable {
    // 基础身份
    let userId: Int?
    let nickname: String?
    let icon: String?
    let sex: Int?              // 1=男 2=女（与 H5 对齐，待真机校验）
    let age: Int?
    let countryCode: String?   // ISO 两字母（"US" 等）；驱动国旗显示

    // 自我介绍
    let signature: String?
    let signatureVaild: Int?   // 1=有效 2=审核中 3=被拒；与 H5 vaild 命名对齐

    // 段位与单价
    let level: Int?            // 主播段位（D/C/NEW/B/A/S/SS 的数字编码，待真机校验编码方式）
    let levelName: String?     // 如 "SS" 字面量；若后端只发数字，此字段为 nil
    let callPrice: Int?        // 单价（/min）

    // 社交数
    let upsNum: Int?           // 关注数 Following
    let fansNum: Int?          // 粉丝数 Followers
    let friendsNum: Int?       // 朋友数 Friends

    // 相册视频（先按数组接，待真机校验元素结构）
    let pictures: [MediaAsset]?
    let videos: [MediaAsset]?

    // 主播专属（H5 蓝本 08 §3.4 / 09 §90）
    let greetMsgs: [String]?       // 问候语，≤50字/条
    let callVideoUrl: String?      // 来电视频
    let giftList: [GiftItem]?      // 礼物墙（userProfile 也用此字段）
}

/// 礼物墙单项（蓝本 08 §3.4「礼物墙 giftList」）。
/// 字段全 Optional：H5 字段名为 H5 推测；真机校验后迭代。
struct GiftItem: Codable, Identifiable, Hashable {
    let giftId: Int?
    let name: String?
    let iconUrl: String?
    let count: Int?               // 收到的件数

    var id: String { "\(giftId ?? -1)-\(name ?? "")" }

    enum CodingKeys: String, CodingKey {
        case giftId = "id"
        case name, iconUrl, count
    }
}

/// 相册/视频条目（用于 pictures[] / videos[]）。
/// 字段集来自蓝本 08 §3.4「均带审核态」；具体字段名以真机响应为准，先按 H5 常用命名占位。
struct MediaAsset: Codable, Identifiable, Hashable {
    let assetId: Int?          // 接口字段：元素自身 id（接口若用 String 再迭代）
    let url: String?           // 资源 URL
    let coverUrl: String?      // 视频封面；图片为 nil
    let vaild: Int?            // 1=有效 2=审核中 3=被拒（H5 拼写沿用）
    let createTime: Int?       // 毫秒时间戳

    /// Identifiable.id：优先用接口 id，没有则用 URL 哈希兜底，仍空才用全 0
    /// （nil 在多元素中冲突，转 String 保证可哈希且唯一）
    var id: String { "\(assetId ?? -1)-\(url ?? "")" }

    enum CodingKeys: String, CodingKey {
        case assetId = "id"  // 接口字段名为 "id"，本地避开协议名冲突
        case url, coverUrl, vaild, createTime
    }
}
