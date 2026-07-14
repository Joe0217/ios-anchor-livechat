import Foundation

/// 派对房礼物架 v2 响应（对齐 H5 用户端 `apiPartyGetRoomGift` · showType=0/apiVersion=2）。
///
/// **主结构 v2**（`stores/modules/party.js:1285`）：
/// ```
/// { tabs: [{tabCode, tabName, tabSort, gifts}], userDiamond, sendGiftConfig }
/// ```
///
/// **v1 fallback**（灰度关闭 apiVersion=2 时后端自动回退 · `party.js:1347`）：
/// ```
/// { giftInfoDtoList: [{tabName, giftVoList}], userDiamond, sendGiftConfig }
/// ```
///
/// **`userDiamond` 一体化**（review #2）：v2/v1 都返 `userDiamond` → iOS 直接从此 response 拿余额，
/// **不额外调 `gem/getBalance`**（H5 gift.js:1359 `if (res?.userDiamond !== undefined) partyGiftConfig.userDiamond = res.userDiamond`）。
///
/// 未识别 tabCode 由 `GiftPanelTab.fromGroupName` 静默 drop。
struct PartyGiftV2Response: Decodable {
    /// v2 结构 · tabs 数组；灰度关闭时可能为空/缺失
    let tabs: [Tab]?
    /// v1 fallback · 灰度关闭时后端返此结构（`party.js:1347`）
    let giftInfoDtoList: [V1Tab]?
    /// 送礼后新余额（v2/v1 共用字段 · `party.js:1360`）—— iOS 直接用避免额外 HTTP
    let userDiamond: Int64?

    struct Tab: Decodable {
        let tabCode: String?
        let tabName: String?
        let tabSort: Int?
        let gifts: [GiftListData]?
    }

    /// v1 fallback tab 结构（`party.js:1348-1350`：tabName 匹配 partyGiftList key、giftVoList 是礼物数组）
    struct V1Tab: Decodable {
        let tabName: String?
        let giftVoList: [GiftListData]?
    }
}
