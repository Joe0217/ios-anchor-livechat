import Foundation

// MARK: - 业务模型

/// 私密媒体单项（H-2 spec §2.1 v2）。
///
/// - `id`：后端 id（服务端持久化）或 `"local_<uuid>"`（本地新增未提交态）
/// - `originalUrl`：图片场景=`giftIcon`（响应字段名） / 视频场景=`videoUrl`
/// - `signedUrl` + `signedAt`：视频专用。图片直用 originalUrl；视频需 getPrivateOssUploadParam 解密
/// - `giftId`：**String/Int 兼容**（参 `.claude/rules/ios-decode-userid-compat.md`，H5 响应字段是 `gift`）
struct PrivateMedia: Identifiable, Equatable {
    let id: String
    let iconType: Int         // 1=图片 / 2=视频
    let originalUrl: String
    var signedUrl: String?
    var signedAt: Date?
    var giftId: String
    var giftName: String?
    var giftPrice: Int?
    /// V2 私密消息列表返回的发送开关。`false` 表示审核中、已拒绝或达到当日限制，聊天页不可选发。
    var sendFlag: Bool = true
    /// V2 审核状态：0 无需审核 / 1 审核中 / 2 已通过 / 3 已拒绝。
    var privateAuditStatus: Int? = nil
    /// 审核拒绝原因（服务端可能不返回，保留供后续详情页展示）。
    var auditReason: String? = nil

    var isNew: Bool { id.hasPrefix("local_") }
    var isImage: Bool { iconType == 1 }
    var isVideo: Bool { iconType == 2 }
    var isSendable: Bool {
        sendFlag && privateAuditStatus != 1 && privateAuditStatus != 3
    }
}

/// 提交 diff 单项（H-2 spec §1.4）。
///
/// 三态：新增（id=nil）/ 未改动（id 非 nil, removePrivate=nil）/ 删除（id 非 nil, removePrivate=true）。
///
/// **id 输出契约**（H-2 step 3 反悔 #1）：
/// H5 `requestData.push({ id: originalItem.id })` 原样透传（server 返 Number 就送 Number）。
/// server 端按 Number 主键匹配 → iOS 早期送 String 无法命中 → 删除操作静默忽略。
/// 手写 `encode(to:)` 让 id 优先输出 Int64；非数字字符串回落 String（防未来 uuid 类 id）。
struct PrivateMediaOp: Equatable {
    let id: String?
    let iconType: Int
    let picList: String?
    let videoUrl: String?
    let giftId: Int
    let removePrivate: Bool?
}

extension PrivateMediaOp: Encodable {
    private enum CodingKeys: String, CodingKey {
        case id, iconType, picList, videoUrl, giftId, removePrivate
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // 关键：id 输出保 H5 原始 Number 类型（server 主键匹配敏感）
        if let idStr = id {
            if let n = Int64(idStr) {
                try c.encode(n, forKey: .id)
            } else {
                try c.encode(idStr, forKey: .id)
            }
        }
        try c.encode(iconType, forKey: .iconType)
        try c.encodeIfPresent(picList, forKey: .picList)
        try c.encodeIfPresent(videoUrl, forKey: .videoUrl)
        try c.encode(giftId, forKey: .giftId)
        try c.encodeIfPresent(removePrivate, forKey: .removePrivate)
    }
}

/// 上传限额响应。
///
/// `privateVedioNum` H5 拼写保留（后端契约）。
///
/// **decode 兼容策略**（[.claude/rules/ios-decode-userid-compat.md](../../../.claude/rules/ios-decode-userid-compat.md)）：
/// H5 `type.ts` 声明 `number` 但后端历史多次混发 String/Number；
/// iOS 严格 `Int` decode 会 fail-loud 让 fetchLimit 回落 default 3/3 —— 用户看到 iOS 限制 3 但 H5 显示 5 就是这个 bug。
/// 双兼容 decode 保 API 返值不因类型偷换失效。
struct PrivateMediaLimit: Equatable {
    let privateNum: Int
    let privateVedioNum: Int
    static let `default` = PrivateMediaLimit(privateNum: 3, privateVedioNum: 3)

    init(privateNum: Int, privateVedioNum: Int) {
        self.privateNum = privateNum
        self.privateVedioNum = privateVedioNum
    }
}

extension PrivateMediaLimit: Decodable {
    private enum CodingKeys: String, CodingKey {
        case privateNum, privateVedioNum
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        privateNum = Self.decodeInt(c, key: .privateNum) ?? 3
        privateVedioNum = Self.decodeInt(c, key: .privateVedioNum) ?? 3
    }

    /// String / Int 双兼容 + Bool 桥接排除
    private static func decodeInt(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Int? {
        if let i = try? c.decode(Int.self, forKey: key) { return i }
        if let s = try? c.decode(String.self, forKey: key), let i = Int(s) { return i }
        return nil
    }
}

/// 视频签名响应（getPrivateOssUploadParam 返回）。
struct PrivateOssParam: Decodable, Equatable {
    let cdnUrl: String
    let authorizationParam: String
}

/// 礼物选择项（简化版，只含 UI 必需字段）。
struct GiftMessageItem: Identifiable, Equatable {
    let id: String
    let name: String
    let iconUrl: String?
    let price: Int
}

// MARK: - 状态机（spec §3）

/// 页面加载态。
enum GiftMessageLoadState: Equatable {
    case idle
    case loading
    case loaded
    case error(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .error(let m) = self { return m }
        return nil
    }
}

// MARK: - 数据层 protocol

/// 业务数据层（4 接口 + 礼物列表）。
protocol GiftMessageServiceProtocol {
    func fetchLimit() async throws -> PrivateMediaLimit
    func fetchList(userId: Int) async throws -> [PrivateMedia]
    func save(ops: [PrivateMediaOp]) async throws
    /// 视频解密（返签名 URL）。内部含 `searchValue` 主 + `search` fallback（spec §2.4）。
    func decryptVideoUrl(originalUrl: String) async throws -> String
    func fetchGifts() async throws -> [GiftMessageItem]
}

/// OSS 上传层（图片走 ImageUploader / 视频走 STS + acl=private）。
protocol PrivateMediaUploadServiceProtocol {
    func uploadImage(_ data: Data) async throws -> String
    /// 视频上传返 originalUrl（提交时用；读取时需另调 decryptVideoUrl）。
    func uploadVideo(fileURL: URL) async throws -> String
}

// MARK: - Decode helper

/// 从 dict 解析 PrivateMedia（手写以支持字段别名映射）。
///
/// **别名映射**（spec §1.4）：
/// - `giftIcon`（图片URL 响应） / `videoUrl`（视频URL） → `originalUrl`
/// - `gift`（响应字段名，可 Int 或 String） → `giftId`（内部收 String）
///
/// 字段缺失或 iconType 非 1/2 返 nil（R-10）。
enum PrivateMediaDecoder {
    static func decode(from dict: [String: Any]) -> PrivateMedia? {
        // iconType 严格 1/2
        guard let iconType = Self.decodeInt(dict["iconType"]), iconType == 1 || iconType == 2 else {
            return nil
        }

        // id 必填（后端返回项都有）
        guard let id = (dict["id"] as? String) ?? (dict["id"] as? NSNumber).map({ $0.stringValue }),
              !id.isEmpty else {
            return nil
        }

        // originalUrl：iconType=1 从 giftIcon；iconType=2 从 videoUrl
        let urlField = iconType == 1 ? "giftIcon" : "videoUrl"
        guard let originalUrl = dict[urlField] as? String, !originalUrl.isEmpty else {
            return nil
        }

        // giftId：响应字段名 gift，支持 String / Int（rule ios-decode-userid-compat）
        var giftIdStr: String?
        if let s = (dict["gift"] as? String) ?? (dict["giftId"] as? String), !s.isEmpty {
            giftIdStr = s
        } else if let n = (dict["gift"] as? NSNumber) ?? (dict["giftId"] as? NSNumber) {
            let cType = String(cString: n.objCType)
            if cType != "c" && cType != "B" {
                giftIdStr = n.stringValue
            }
        }
        guard let giftId = giftIdStr, !giftId.isEmpty else { return nil }

        let giftPrice = Self.decodeInt(dict["giftPrice"])
            ?? Self.decodeInt(dict["giftPriceSnapshot"])
        let sendFlag = Self.decodeBool(dict["sendFlag"])
            ?? Self.decodeBool(dict["canSend"])
            ?? true
        let auditStatus = Self.decodeInt(dict["privateAuditStatus"])
            ?? Self.decodeInt(dict["auditStatus"])

        return PrivateMedia(
            id: id,
            iconType: iconType,
            originalUrl: originalUrl,
            signedUrl: nil,
            signedAt: nil,
            giftId: giftId,
            giftName: dict["giftName"] as? String,
            giftPrice: giftPrice,
            sendFlag: sendFlag,
            privateAuditStatus: auditStatus,
            auditReason: dict["auditReason"] as? String
        )
    }

    private static func decodeInt(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func decodeBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let int = value as? Int { return int != 0 }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// 批量解析：跳过非法项，保留合法项。
    static func decodeList(from data: Data) -> [PrivateMedia] {
        if String(data: data, encoding: .utf8) == "null" { return [] }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap(decode(from:))
    }

    // MARK: - Diff 算法（spec §1.5 v2 red team #4）

    /// 计算 diff（id 优先匹配防 url 冲突）。
    ///
    /// **算法**（spec §1.5 v2）：
    /// - 原有 id 在原始列表 + 当前列表移除 → 删除项（带 id + removePrivate=true）
    /// - 当前项有后端 id（!isNew）→ 未改动项（带 id + 全字段）
    /// - 当前项 isNew → 新增项（不带 id）
    static func computeDiff(original: [PrivateMedia], current: [PrivateMedia]) -> [PrivateMediaOp] {
        var ops: [PrivateMediaOp] = []
        let currentIds = Set(current.filter { !$0.isNew }.map(\.id))

        // 1. 删除项（原有 id 但当前不在）
        for item in original {
            guard !item.isNew, !currentIds.contains(item.id) else { continue }
            ops.append(PrivateMediaOp(
                id: item.id,
                iconType: item.iconType,
                picList: item.iconType == 1 ? item.originalUrl : nil,
                videoUrl: item.iconType == 2 ? item.originalUrl : nil,
                giftId: Int(item.giftId) ?? 0,
                removePrivate: true
            ))
        }

        // 2. 当前项：未改动（有后端 id）或新增（本地 id）
        for item in current {
            let id: String? = item.isNew ? nil : item.id
            ops.append(PrivateMediaOp(
                id: id,
                iconType: item.iconType,
                picList: item.iconType == 1 ? item.originalUrl : nil,
                videoUrl: item.iconType == 2 ? item.originalUrl : nil,
                giftId: Int(item.giftId) ?? 0,
                removePrivate: nil
            ))
        }
        return ops
    }
}
