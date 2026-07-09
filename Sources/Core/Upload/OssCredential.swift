import Foundation

/// OSS PostObject 直传凭证（对齐 H5 `/sts/getOssUploadParam` 响应 + 安卓 `InternationOssEntity`）。
///
/// 公共模型，多个业务共用：朋友圈发布 / 反馈截图 / 头像 / 相册 等（Sources/Core/Upload/ 层）。
///
/// **字段类型**：H5/安卓全部按 String 取（即使 expire 是数字）；
/// Codable decode 试 String 失败 fallback Int 转 String（防字段类型偷换）。
struct OssCredential: Decodable, Equatable {
    let accessid: String
    let policy: String
    let signature: String
    let host: String
    let cdnUrl: String
    /// epoch 秒时间戳。上传前应预检 `expire - now < 300s` 触发重拉（R18 / [OssCredentialService](OssCredentialService.swift)）。
    let expire: String

    enum CodingKeys: String, CodingKey {
        case accessid, policy, signature, host, cdnUrl, expire
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessid  = try c.decode(String.self, forKey: .accessid)
        policy    = try c.decode(String.self, forKey: .policy)
        signature = try c.decode(String.self, forKey: .signature)
        host      = try c.decode(String.self, forKey: .host)
        cdnUrl    = try c.decode(String.self, forKey: .cdnUrl)
        // expire 防字段类型偷换：试 String 失败 fallback Int
        if let s = try? c.decode(String.self, forKey: .expire) {
            expire = s
        } else if let i = try? c.decode(Int64.self, forKey: .expire) {
            expire = String(i)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .expire, in: c,
                debugDescription: "expire neither String nor Int64")
        }
    }

    /// 测试用直接构造器（非 Decoder 路径）。
    init(accessid: String, policy: String, signature: String,
         host: String, cdnUrl: String, expire: String) {
        self.accessid = accessid
        self.policy = policy
        self.signature = signature
        self.host = host
        self.cdnUrl = cdnUrl
        self.expire = expire
    }

    /// 是否需要在上传前刷新（凭证过期预检）。
    /// `nowEpoch` 注入便于单测；生产传 `Date().timeIntervalSince1970`。
    func shouldRefresh(nowEpoch: TimeInterval, safetyMargin: TimeInterval = 300) -> Bool {
        guard let exp = TimeInterval(expire) else { return true }  // 解析失败保守重拉
        return exp - nowEpoch < safetyMargin
    }
}
