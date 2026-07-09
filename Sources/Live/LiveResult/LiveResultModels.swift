import Foundation

/// 直播结果页数据模型（对齐 H5 `views/liveEnds/index.vue` + `components/{listItem,topGiftersItem}.vue`）。
///
/// 后端接口 `POST /api/agora/live/queryLiveStat` 返回字段：
/// - `viewNum` Int：直播间观众数
/// - `followNum` Int：本场关注新增数
/// - `giftRanks` [GiftRankItem]：送礼排行榜（有序，前 3 作 top gifters 预览）
/// - `incomeDiamonds` Int：本场收益钻石
/// - `privateCalls` [PrivateCallItem]：本场私 call 记录（callDuration 秒）

struct LiveStatData: Equatable {
    let viewNum: Int
    let followNum: Int
    let incomeDiamonds: Int
    var giftRanks: [GiftRankItem]           // var：follow 后就地更新 followFlag
    var privateCalls: [PrivateCallItem]     // 同上

    /// H5 侧 `giftRanks.slice(0, 3)` 作 top gifters 预览
    var giftRanksReview: [GiftRankItem] { Array(giftRanks.prefix(3)) }
}

/// 单个送礼用户项。
///
/// **userId String/Int 双兼容**（.claude/rules/ios-decode-userid-compat.md）：H5 `type.ts`
/// 声明的类型不可信，H-0 trial #3 已证实真接口混发 Number/String。
///
/// **followFlag Int/Bool 双兼容**：H5 模板 `item.followFlag * 1 !== 1` 是宽松乘法转数字，
/// 后端可能返 Bool、Int 1、Int 0；本 model 收窄为 Bool，解码层做兼容。
struct GiftRankItem: Equatable, Identifiable {
    let userId: String
    let icon: String?
    let nickname: String?
    let consumeDiamonds: Int
    var followed: Bool           // followFlag == 1 → true
    let yxAccid: String?         // 无则 Message 按钮不显示

    var id: String { userId }
}

/// 单个私 call 记录（对齐 H5 listItem showCall=true 分支）。
struct PrivateCallItem: Equatable, Identifiable {
    let userId: String
    let icon: String?
    let nickname: String?
    let callDurationSeconds: Int   // 秒（H5 侧 formatTimestamp(callDuration * 1000)）
    var followed: Bool
    let yxAccid: String?

    /// 稳定 id：userId 可能重复（同一用户多通话），复合 index 见 View 层
    var id: String { userId }
}
