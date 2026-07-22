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

    /// v7.5：手写 init 让 id / duration String/Int 双兼容 —— 若真机后端返 `"12"` 字符串会让
    /// 默认 Codable 挂（`Expected Int, found String`）→ decodeArrayOrEmpty 整个数组 fail →
    /// backgrounds 恒空 → 用户无法选背景。ios-decode-userid-compat rule 同源精神。
    enum CodingKeys: String, CodingKey {
        case id, imgUrl, bigImgUrl, bgImgName, duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let n = try? c.decode(Int.self, forKey: .id) {
            id = n
        } else if let s = try? c.decode(String.self, forKey: .id), let n = Int(s) {
            id = n
        } else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "id neither Int nor Int-string")
        }
        imgUrl = try? c.decode(String.self, forKey: .imgUrl)
        bigImgUrl = try? c.decode(String.self, forKey: .bigImgUrl)
        bgImgName = try? c.decode(String.self, forKey: .bgImgName)
        if let n = try? c.decode(Int.self, forKey: .duration) {
            duration = n
        } else if let s = try? c.decode(String.self, forKey: .duration), let n = Int(s) {
            duration = n
        } else {
            duration = nil
        }
    }
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

/// Party 房基础配置。当前消费管理端踢人限时，避免把服务端值硬编码到 UI。
struct PartyBaseConfig: Decodable, Equatable {
    let kickOutInterval: Int?

    private enum CodingKeys: String, CodingKey {
        case kickOutInterval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(Int.self, forKey: .kickOutInterval) {
            kickOutInterval = value
        } else if let value = try? container.decode(String.self, forKey: .kickOutInterval) {
            kickOutInterval = Int(value)
        } else {
            kickOutInterval = nil
        }
    }
}
