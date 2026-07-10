import Foundation

/// PK 贡献榜 side（点击 Top3 一侧决定拉哪一方 anchorId 的 rank）。
///
/// 对齐 H5 `pkRankListPopup.vue` `props.side: 'my' | 'opponent'`。
enum PKRankSide: String, Identifiable, Equatable {
    case my
    case opponent

    var id: String { rawValue }
}

/// PK 贡献榜单条条目（`POST /api/pk/getPkRankList` 响应元素）。
///
/// H5 [pkRankListPopup.vue L124-203] row 渲染字段：
/// - `anchorId` 上榜用户 id（在线状态定位用）；String/Int 双兼容（[ios-decode-userid-compat]）
/// - `avatar` 头像 URL
/// - `nickName` 昵称（H5 `item.nickName || 'User'`）
/// - `levelName` 等级标签（可选，`v-if="item.levelName"`）
/// - `isVip` VIP 标识（可选）
/// - `countryId` 国家 id（可选，显示 chip）
/// - `contribution` 贡献值（H5 `item.contribution || 0`）
struct PKRankItem: Identifiable, Equatable {
    /// 上榜用户 id（用于 in-row a11y + 未来定位在线状态）
    let anchorId: String
    let avatar: String?
    let nickName: String?
    let levelName: String?
    let isVip: Bool
    let countryId: String?
    let contribution: Int

    /// LazyVStack ForEach id：优先 anchorId，为空时不会入榜（decoder 里 guard）
    var id: String { anchorId }
}

extension PKRankItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case anchorId
        case userId          // 兼容后端字段命名不一致（若下发 userId 而非 anchorId）
        case avatar, icon    // icon 兼容 attachType=98 语义
        case nickName, nickname
        case levelName
        case isVip
        case countryId
        case contribution, value   // value 兼容 attachType=98 语义
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // anchorId 字段双兼容（String / Int），fallback userId（[ios-decode-userid-compat]）
        var anchorIdStr: String?
        for key in [CodingKeys.anchorId, .userId] {
            if let s = try? c.decode(String.self, forKey: key), !s.isEmpty {
                anchorIdStr = s; break
            }
            if let i = try? c.decode(Int64.self, forKey: key) {
                anchorIdStr = String(i); break
            }
        }
        guard let id = anchorIdStr, !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .anchorId, in: c,
                                                   debugDescription: "anchorId/userId missing")
        }
        self.anchorId = id

        self.avatar = (try? c.decode(String.self, forKey: .avatar))
            ?? (try? c.decode(String.self, forKey: .icon))
        self.nickName = (try? c.decode(String.self, forKey: .nickName))
            ?? (try? c.decode(String.self, forKey: .nickname))
        self.levelName = try? c.decode(String.self, forKey: .levelName)
        self.isVip = (try? c.decode(Bool.self, forKey: .isVip)) ?? false
        self.countryId = try? c.decode(String.self, forKey: .countryId)

        // contribution 值：优先 contribution，fallback value；后端也可能发字符串数字（保险 String → Int）
        if let n = try? c.decode(Int.self, forKey: .contribution) {
            self.contribution = n
        } else if let n = try? c.decode(Int.self, forKey: .value) {
            self.contribution = n
        } else if let s = try? c.decode(String.self, forKey: .contribution), let n = Int(s) {
            self.contribution = n
        } else if let s = try? c.decode(String.self, forKey: .value), let n = Int(s) {
            self.contribution = n
        } else {
            self.contribution = 0
        }
    }
}
