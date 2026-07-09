import Foundation

// MARK: - 业务模型

/// 用户列表条目（H5 `getUserList` 响应 item）。
///
/// 字段对应 H5 `views/home/components/list.vue` 模板用法：
/// - `userId`（key field，H5 数字字符串混用 → 这里收为 String 兼容）
/// - `nickname` 主标题
/// - `icon` 头像 url（可空）
/// - `userLevel` 字符串"0"表示不显示 Lv 徽章
/// - `vipExpireTime` 毫秒时间戳，> 当前时间显示 VIP 徽章
/// - `country` 国名/地区文本
/// - `yxAccid` 云信账号，跳私聊 / 1v1 视频通话用
struct LiveListAnchor: Identifiable, Equatable {
    let userId: String
    let nickname: String
    let icon: String?
    let userLevel: String?
    let vipExpireTimeMs: Int64?
    let country: String?
    let yxAccid: String?

    var id: String { userId }

    var hasVipBadge: Bool {
        guard let ms = vipExpireTimeMs else { return false }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return ms > nowMs
    }

    /// `userLevel` 非 nil 且非 "0" 才显示 Lv 徽章（对齐 H5 `item.userLevel !== '0'`）
    var hasLevelBadge: Bool {
        guard let lv = userLevel else { return false }
        return lv != "0"
    }
}

extension LiveListAnchor: Decodable {
    enum CodingKeys: String, CodingKey {
        case userId, nickname, icon, userLevel, country, yxAccid
        case vipExpireTimeMs = "vipExpireTime"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // userId 接口侧 String/Int 混发，统一收为 String
        if let s = try? c.decode(String.self, forKey: .userId) {
            userId = s
        } else if let i = try? c.decode(Int64.self, forKey: .userId) {
            userId = String(i)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .userId, in: c, debugDescription: "userId neither String nor Int64")
        }
        nickname = (try? c.decode(String.self, forKey: .nickname)) ?? ""
        icon = try? c.decode(String.self, forKey: .icon)
        userLevel = try? c.decode(String.self, forKey: .userLevel)
        vipExpireTimeMs = try? c.decode(Int64.self, forKey: .vipExpireTimeMs)
        country = try? c.decode(String.self, forKey: .country)
        yxAccid = try? c.decode(String.self, forKey: .yxAccid)
    }
}

// MARK: - segment

/// List 子页顶部 Online/Prime 切换。对齐 H5 `homeConfig.ts listTabList`。
///
/// segment 切换会**触发数据重拉**（H5 行为：online→`keyword=1`、prime→`keyword=2`）。
/// 纯枚举 + `keyword` 编码，**零 L10n 依赖**（label 在 `LiveListSegment+Label.swift`）。
enum LiveListSegment: CaseIterable, Hashable {
    case online, prime

    /// H5 `getUserList` 接口的 `keyword` 参数。
    var keyword: Int {
        switch self {
        case .online: return 1
        case .prime:  return 2
        }
    }
}

// MARK: - 状态机

/// 列表加载态。对齐 Blocklist trial #2 模式（loadingFirstPage / loadingMore / loaded / error）。
enum LiveListLoadState: Equatable {
    case idle
    case loadingFirstPage
    case loadingMore
    case loaded
    case error(String)

    var isLoading: Bool {
        switch self {
        case .loadingFirstPage, .loadingMore: return true
        default: return false
        }
    }

    var errorMessage: String? {
        if case .error(let m) = self { return m }
        return nil
    }
}

// MARK: - 数据层 protocol

/// `/api/index/getUserList` 数据层 protocol。
/// 单测注入 Fake；真集成走 `LiveListService.shared`。
protocol LiveListServiceProtocol {
    /// 拉一页用户列表。
    /// - parameter keyword: 对齐 H5：`1`=Online、`2`=Prime
    /// - parameter currentPage: 1-based 页码
    /// - parameter pageSize: 单页条数（H5 写 20）
    func fetchUsers(keyword: Int, currentPage: Int, pageSize: Int) async throws -> [LiveListAnchor]
}
