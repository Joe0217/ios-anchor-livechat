import Foundation

/// 派对房背景图（`room/getBgImages` 返回）。
///
/// 对齐 H5 用户端 `livechat-h5/src/api/party/index.ts:254 apiGetPartyBgImages`
/// 与安卓 `partyroom/entity/PartyRoomBackground.kt`。
///
/// 字段名来源：H5 index.ts 声明 —— **待真机 log 验证**
/// （见 [.claude/rules/agent-recon-field-names-unverified.md](../../../.claude/rules/agent-recon-field-names-unverified.md)）
struct PartyBackground: Decodable, Identifiable, Equatable, Hashable {
    let id: Int
    let imgUrl: String?      // 缩略图（网格列表用）
    let bigImgUrl: String?   // 大图（房间背景实际使用）
    let bgImgName: String?
    /// `duration <= 0` 视为 Permanent 永久，否则倒计时（秒）
    let duration: Int?

    var isPermanent: Bool { (duration ?? 0) <= 0 }
}

/// 创房权限校验（`room/getCreateRoomConditions` 返回）。
///
/// 对齐 H5 用户端 `livechat-h5/src/api/party/index.ts:63 apiGetPartyRoomAuth`
/// 与安卓 `entity/CreatePartyRoomConditions.kt`。
struct PartyCreateConditions: Decodable, Equatable {
    let canCreateRoom: Bool
    let createRoomLevel: Int?
    /// H5 拼写：`isWithlist`（漏 h），保留原字面兼容
    let isWithlist: Bool?
}
