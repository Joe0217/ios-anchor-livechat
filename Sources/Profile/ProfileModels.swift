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
    // ⚠️ 真接口返 picList 单一数组（mediaType 1=图 2=视频），这两个字段实测**永远为 nil**；
    // 保留仅供极端 fallback，photos/videos UI 派生优先从 picList 分流（见 AnchorInfoStore）
    let pictures: [MediaAsset]?
    let videos: [MediaAsset]?

    // H5 蓝本 mine/index.vue:259 `mineInfo.picList` —— getAnchorInfo 真实返的相册字段
    // 元素结构对齐 UserInfoWithReviewResponse.PicListItem（EditProfile 已用同款）
    // 独立命名 `AnchorPicItem` 避免与他处 PicListItem 混淆
    let picList: [AnchorPicItem]?

    // 主播专属（H5 蓝本 08 §3.4 / 09 §90）
    let greetMsgs: [GreetMsg]?     // 问候语（含 id 支持编辑页删除 diff），≤50字/条
    let callVideoUrl: String?      // 来电视频
    let giftList: [GiftItem]?      // 礼物墙（userProfile 也用此字段）

    // H-3 新增（对齐 H5 私聊页深化）
    let chatBubble: String?        // 主播穿戴的气泡装扮 URL（H5 `mineInfo.chatBubble`，来自虚拟道具 itemType=4)
    let activeTycoon: Bool?        // 主播自己是否大R（发送消息时 remoteExt 透传给对端，让对端 nav 显徽章）

    // 工作台数据（H5 mineInfo.dataStatistics + anchorIncomeMap；H5 type.ts 声明 anchorIncomeMap?: null 是撒谎，真接口返 dict）
    let dataStatistics: AnchorDataStatistics?
    let anchorIncomeMap: AnchorIncomeMap?

    // A-2 新增（v3 BLOCK-2 修：供注册被拒重录 hydrate 回填；H5 `type.ts` L67/78/115/195 等多处 mineInfo 类型声明字段名推）
    let email: String?             // 注册用邮箱；H5 `type.ts:67` `email?: string` / L195 `email: string`
    /// birthday："yyyy-MM-dd" 或 number timestamp（H5 type.ts:21/51 声明 number / L78/115 声明 string，后端混发）；
    /// Finding #8 修 2026-07-10：Codable init(from:) 里通过 `KeyedDecodingContainer.decodeFlexibleString` String/Int/Double 兼容 decode，对齐 rule ios-decode-userid-compat.md
    let birthday: String?
    let phone: String?             // 手机号；H5 `type.ts:68`
    let inviteCode: String?        // 邀请码；对齐 H5 register `formData.inviteCode`
    let language: String?          // 已学语言 逗号 join（对齐 H5 register `formData.language`）
    let countryId: String?         // ⚠️ 与 countryCode（ISO 两字母）不同：H5 register formData.countryId 是 en 名（"Spain"）或 locale，抓包定；先 String?

    // Finding #8 修 2026-07-10：手写 init(from:) 让 birthday 支持 String/Int/Double 混发 decode
    // 其它字段沿用 decodeIfPresent 语义（与 Swift 自动 synthesized 一致；写全一遍是因为一旦手写 init(from:) 就会禁用 auto synthesize）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.userId = try c.decodeIfPresent(Int.self, forKey: .userId)
        self.nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
        self.sex = try c.decodeIfPresent(Int.self, forKey: .sex)
        self.age = try c.decodeIfPresent(Int.self, forKey: .age)
        self.countryCode = try c.decodeIfPresent(String.self, forKey: .countryCode)
        self.signature = try c.decodeIfPresent(String.self, forKey: .signature)
        self.signatureVaild = try c.decodeIfPresent(Int.self, forKey: .signatureVaild)
        self.level = try c.decodeIfPresent(Int.self, forKey: .level)
        self.levelName = try c.decodeIfPresent(String.self, forKey: .levelName)
        self.callPrice = try c.decodeIfPresent(Int.self, forKey: .callPrice)
        self.upsNum = try c.decodeIfPresent(Int.self, forKey: .upsNum)
        self.fansNum = try c.decodeIfPresent(Int.self, forKey: .fansNum)
        self.friendsNum = try c.decodeIfPresent(Int.self, forKey: .friendsNum)
        self.pictures = try c.decodeIfPresent([MediaAsset].self, forKey: .pictures)
        self.videos = try c.decodeIfPresent([MediaAsset].self, forKey: .videos)
        self.picList = try c.decodeIfPresent([AnchorPicItem].self, forKey: .picList)
        self.greetMsgs = try c.decodeIfPresent([GreetMsg].self, forKey: .greetMsgs)
        self.callVideoUrl = try c.decodeIfPresent(String.self, forKey: .callVideoUrl)
        self.giftList = try c.decodeIfPresent([GiftItem].self, forKey: .giftList)
        self.chatBubble = try c.decodeIfPresent(String.self, forKey: .chatBubble)
        self.activeTycoon = try c.decodeIfPresent(Bool.self, forKey: .activeTycoon)
        self.dataStatistics = try c.decodeIfPresent(AnchorDataStatistics.self, forKey: .dataStatistics)
        self.anchorIncomeMap = try c.decodeIfPresent(AnchorIncomeMap.self, forKey: .anchorIncomeMap)
        self.email = try c.decodeIfPresent(String.self, forKey: .email)
        // birthday: String/Int/Double 兼容（对齐 ios-decode-userid-compat.md）
        self.birthday = c.decodeFlexibleString(forKey: .birthday)
        self.phone = try c.decodeIfPresent(String.self, forKey: .phone)
        self.inviteCode = try c.decodeIfPresent(String.self, forKey: .inviteCode)
        self.language = try c.decodeIfPresent(String.self, forKey: .language)
        self.countryId = try c.decodeIfPresent(String.self, forKey: .countryId)
    }

    /// Memberwise init 保留供 EditProfileView+Preview 等 test/preview 代码继续用位置参数构造
    init(userId: Int?, nickname: String?, icon: String?, sex: Int?, age: Int?,
         countryCode: String?, signature: String?, signatureVaild: Int?,
         level: Int?, levelName: String?, callPrice: Int?,
         upsNum: Int?, fansNum: Int?, friendsNum: Int?,
         pictures: [MediaAsset]?, videos: [MediaAsset]?, picList: [AnchorPicItem]? = nil,
         greetMsgs: [GreetMsg]?,
         callVideoUrl: String?, giftList: [GiftItem]?,
         chatBubble: String?, activeTycoon: Bool?,
         dataStatistics: AnchorDataStatistics? = nil, anchorIncomeMap: AnchorIncomeMap? = nil,
         email: String?, birthday: String?, phone: String?, inviteCode: String?,
         language: String?, countryId: String?) {
        self.userId = userId; self.nickname = nickname; self.icon = icon; self.sex = sex; self.age = age
        self.countryCode = countryCode; self.signature = signature; self.signatureVaild = signatureVaild
        self.level = level; self.levelName = levelName; self.callPrice = callPrice
        self.upsNum = upsNum; self.fansNum = fansNum; self.friendsNum = friendsNum
        self.pictures = pictures; self.videos = videos; self.picList = picList
        self.greetMsgs = greetMsgs
        self.callVideoUrl = callVideoUrl; self.giftList = giftList
        self.chatBubble = chatBubble; self.activeTycoon = activeTycoon
        self.dataStatistics = dataStatistics; self.anchorIncomeMap = anchorIncomeMap
        self.email = email; self.birthday = birthday; self.phone = phone; self.inviteCode = inviteCode
        self.language = language; self.countryId = countryId
    }
}

/// KeyedDecodingContainer helper：字段可能是 String / Int / Double / null 时的兼容 decode
/// 对齐 .claude/rules/ios-decode-userid-compat.md 精神——H5 接口混发数字/字符串是常态，不能严格 String decode
extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key) -> String? {
        // `try?` 已把 `T??` flatten 成 `T?`（Swift 5+），单层 if let 就够；
        // 若再写 `, let s` 是对已解开的 non-optional String 再解一次 → "conditional binding must have Optional" 报错
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int64.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(Int64(d)) }
        return nil
    }

    /// Int 版：接口混发 Int / String / Double 时的兼容 decode
    func decodeFlexibleInt(forKey key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let s = try? decodeIfPresent(String.self, forKey: key), let i = Int(s) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        return nil
    }
}

/// 主播工作台数据统计（H5 `mineInfo.dataStatistics`，getAnchorInfo 响应字段）。
/// H5 蓝本 work/index.vue L498/509/520：`callNum` 是**在线时长**（秒），`weeklyDiamonds` 是**平均通话时长**（秒），
/// 字段名 H5 复用未纠正，业务语义已跑偏；本文件的 doc comment 描述业务语义为准。
struct AnchorDataStatistics: Codable, Equatable {
    let callNum: Int?           // 今日在线时长（秒）
    let weeklyDiamonds: Int?    // 今日平均通话时长（秒）
    let positiveRating: Int?    // 好评率（0-100 整数）

    init(callNum: Int? = nil, weeklyDiamonds: Int? = nil, positiveRating: Int? = nil) {
        self.callNum = callNum
        self.weeklyDiamonds = weeklyDiamonds
        self.positiveRating = positiveRating
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.callNum = c.decodeFlexibleInt(forKey: .callNum)
        self.weeklyDiamonds = c.decodeFlexibleInt(forKey: .weeklyDiamonds)
        self.positiveRating = c.decodeFlexibleInt(forKey: .positiveRating)
    }
}

/// 今日收益字典（H5 `mineInfo.anchorIncomeMap`）。
/// H5 蓝本 work/index.vue L279 `mappedIncomeItems`：值直接与 UI 拼接 + `|| '0'` 兜底 → 类型按 String? 处理；
/// 后端混发 Int/String 由 flexible decode 统一收敛到 String。
struct AnchorIncomeMap: Codable, Equatable {
    let totalCoin: String?
    let callIncome: String?
    let giftIncome: String?
    let taskReward: String?
    let invitationReward: String?
    let unlock: String?

    init(totalCoin: String? = nil, callIncome: String? = nil, giftIncome: String? = nil,
         taskReward: String? = nil, invitationReward: String? = nil, unlock: String? = nil) {
        self.totalCoin = totalCoin
        self.callIncome = callIncome
        self.giftIncome = giftIncome
        self.taskReward = taskReward
        self.invitationReward = invitationReward
        self.unlock = unlock
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.totalCoin = c.decodeFlexibleString(forKey: .totalCoin)
        self.callIncome = c.decodeFlexibleString(forKey: .callIncome)
        self.giftIncome = c.decodeFlexibleString(forKey: .giftIncome)
        self.taskReward = c.decodeFlexibleString(forKey: .taskReward)
        self.invitationReward = c.decodeFlexibleString(forKey: .invitationReward)
        self.unlock = c.decodeFlexibleString(forKey: .unlock)
    }
}

/// 问候语单条（I-spec-用户资料编辑页 §2.2）。
///
/// H5 蓝本 `greetMsgBtn.vue:45` `item.contentDetail` 反推真实结构含 id + contentDetail
/// 对象数组（H5 `type.ts:106` 声明 `string[]` 是撒谎，对齐 rule ios-decode-userid-compat 精神）。
/// 编辑页删除 diff 依赖 id；新增时 addGreetList 只传 contentDetail。
///
/// 命名沿用 `MediaAsset` / `GiftItem` 模式：接口字段名 "id" 解到本地 `serverId`
/// 避开 `Identifiable.id` 协议名冲突。
struct GreetMsg: Codable, Identifiable, Hashable {
    let serverId: Int?         // 接口字段：id（老 v1 缓存无此字段则为 nil）
    let contentDetail: String?

    /// Identifiable.id：优先接口 id，缺则用 content 兜底
    var id: String { "\(serverId ?? -1)-\(contentDetail ?? "")" }

    enum CodingKeys: String, CodingKey {
        case serverId = "id"
        case contentDetail
    }
}

/// 礼物墙单项（蓝本 08 §3.4「礼物墙 giftList」）。
///
/// 字段名双兼容（对齐 H5 mine/components/gifts.vue L21/24/27）：
/// - 图 URL：`giftImg` || `icon` || `iconUrl`
/// - 名字：`giftName` || `name`
/// - 数量：`giftCount` || `num` || `count`
/// - 主键：`giftId` || `id`
///
/// 来源接口：`/api/anchor/getGiftWallList`（独立于 getAnchorInfo；H5 mine/index.vue:92）；
/// UserProfile 详情 `giftList` 走用户接口返 `giftId`+`num` 简版。
struct GiftItem: Codable, Identifiable, Hashable {
    let giftId: Int?
    let name: String?
    let iconUrl: String?
    let count: Int?               // 收到的件数

    var id: String { "\(giftId ?? -1)-\(name ?? "")" }

    init(giftId: Int?, name: String?, iconUrl: String?, count: Int?) {
        self.giftId = giftId
        self.name = name
        self.iconUrl = iconUrl
        self.count = count
    }

    private enum CodingKeys: String, CodingKey {
        case giftId, id
        case name, giftName
        case iconUrl, giftImg, icon
        case count, giftCount, num
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // giftId：接口给 Int，兼容 String
        if let i = try? c.decode(Int.self, forKey: .giftId) { giftId = i }
        else if let s = try? c.decode(String.self, forKey: .giftId) { giftId = Int(s) }
        else if let i = try? c.decode(Int.self, forKey: .id) { giftId = i }
        else if let s = try? c.decode(String.self, forKey: .id) { giftId = Int(s) }
        else { giftId = nil }
        // 名字
        name = (try? c.decode(String.self, forKey: .giftName))
            ?? (try? c.decode(String.self, forKey: .name))
        // 图 URL：H5 gifts.vue `giftImg || icon`；有些接口用 iconUrl
        iconUrl = (try? c.decode(String.self, forKey: .giftImg))
            ?? (try? c.decode(String.self, forKey: .icon))
            ?? (try? c.decode(String.self, forKey: .iconUrl))
        // 数量：giftCount / num / count 三选一
        if let n = try? c.decode(Int.self, forKey: .giftCount) { count = n }
        else if let n = try? c.decode(Int.self, forKey: .num) { count = n }
        else if let n = try? c.decode(Int.self, forKey: .count) { count = n }
        else { count = nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(giftId, forKey: .giftId)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(iconUrl, forKey: .iconUrl)
        try c.encodeIfPresent(count, forKey: .count)
    }
}

/// 主播个人主页相册项（getAnchorInfo 响应 `picList` 元素）。
///
/// 字段对齐 H5 `PicListData`（src/api/user/type.ts:184）+ EditProfile 侧 `UserInfoWithReviewResponse.PicListItem`。
/// Codable 双向（Encodable 供 AnchorInfoStore CachedSnapshot 持久化）。
struct AnchorPicItem: Codable, Identifiable, Hashable {
    let assetId: Int?          // 接口字段：id
    let mediaUrl: String?      // 图 or 视频 URL
    let mediaType: Int?        // 1=图 2=视频
    let videoCover: String?    // 视频封面（图片项 nil）
    let vaild: Int?            // 1=有效 2=审核中 3=被拒（沿用 H5 拼写）

    var id: String { "\(assetId ?? -1)-\(mediaUrl ?? "")" }

    enum CodingKeys: String, CodingKey {
        case assetId = "id"
        case mediaUrl, mediaType, videoCover, vaild
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
