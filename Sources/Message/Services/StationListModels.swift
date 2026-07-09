import Foundation

/// 站内信 API `POST /api/sysmail/loadList` 响应 model（H-1c 系统消息 3 入口）。
///
/// **接口契约**（H5 `apiGetStationList`）：
/// - Request body: `{"pageSize": Int, "currentPage": Int}`
/// - Response: **APIClient 剥完 envelope + 解密后**是 top-level array of station mail
///   （对齐 Prime 契约同款：非 dict 包装）
///
/// **只取顶部一条**（对齐 H5 `list.vue:154-176` `getStationList` 用 pageSize=1）。
struct StationMail: Decodable, Equatable {
    let id: String
    let mailTitle: String
    let effectiveDate: String
    /// 邮件正文（HTML；Batch 3.8 加，对齐 H5 `stationMsg.vue` `v-html="item.mailContent"`）
    let mailContent: String
    /// 已读状态：0=未读 / 1=已读（对齐 H5 `item.status`）
    let status: Int
    /// 过期时间字符串（对齐 H5 `item.expiryDate`；直接显示不解析）
    let expiryDate: String

    enum CodingKeys: String, CodingKey {
        case id, mailTitle, effectiveDate, mailContent, status, expiryDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // id 后端可能返 String / Int，一律收 String（同 ios-decode-userid-compat 规则）
        if let s = try? c.decode(String.self, forKey: .id) {
            self.id = s
        } else if let i = try? c.decode(Int64.self, forKey: .id) {
            self.id = String(i)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c,
                                                    debugDescription: "id neither String nor Int64")
        }
        self.mailTitle    = (try? c.decodeIfPresent(String.self, forKey: .mailTitle)) ?? ""
        self.effectiveDate = (try? c.decodeIfPresent(String.self, forKey: .effectiveDate)) ?? ""
        self.mailContent  = (try? c.decodeIfPresent(String.self, forKey: .mailContent)) ?? ""
        // status: Int/String 双兼容
        if let i = try? c.decodeIfPresent(Int.self, forKey: .status) { self.status = i }
        else if let s = try? c.decodeIfPresent(String.self, forKey: .status), let i = Int(s) { self.status = i }
        else { self.status = 0 }
        self.expiryDate   = (try? c.decodeIfPresent(String.self, forKey: .expiryDate)) ?? ""
    }

    /// 便利初始化（供 Fake / 单测 / 内存构造）
    init(id: String, mailTitle: String, effectiveDate: String,
         mailContent: String = "", status: Int = 0, expiryDate: String = "") {
        self.id = id
        self.mailTitle = mailTitle
        self.effectiveDate = effectiveDate
        self.mailContent = mailContent
        self.status = status
        self.expiryDate = expiryDate
    }
}
