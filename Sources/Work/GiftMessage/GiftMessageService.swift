import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "GiftMessageService")

/// 私密媒体解锁业务数据层（H-2 spec §2.3 真实现，step 1c）。
///
/// - `fetchLimit`：POST `/api/payPrivateMsg/privatePicNum`（body 空）→ `{privateNum, privateVedioNum}`
/// - `fetchList`：POST `/api/payPrivateMsg/privateInfo` `{userId}` → array（用 `PrivateMediaDecoder.decodeList`）
/// - `save`：POST `/api/payPrivateMsg/uploadPrivateInfo` array body（对齐 H5 `http.post(path, array)`）
/// - `decryptVideoUrl`：POST `/sts/getPrivateOssUploadParam` — H5 两入口字段名分叉（`searchValue` 主 / `search` fallback，spec §1.3 §2.4）
/// - `fetchGifts`：走 [GiftService](../../Gift/GiftService.swift) 拉 IM 场景礼物（H5 secretSettings/index.vue:309 `type="IM"`）
final class GiftMessageService: GiftMessageServiceProtocol {

    static let shared = GiftMessageService()

    private init() {}

    // MARK: - 4 业务接口

    func fetchLimit() async throws -> PrivateMediaLimit {
        let data = try await APIClient.shared.post("/api/payPrivateMsg/privatePicNum", body: [:])
        let raw = String(data: data, encoding: .utf8) ?? "<binary>"
        logger.info("fetchLimit raw=\(raw, privacy: .public)")   // step 3 反悔 #7 诊断：核对 API 返值真实态
        if raw == "null" {
            logger.warning("fetchLimit result=null, using default 3/3")
            return .default
        }
        do {
            let lim = try JSONDecoder().decode(PrivateMediaLimit.self, from: data)
            logger.info("fetchLimit ok pic=\(lim.privateNum, privacy: .public) vid=\(lim.privateVedioNum, privacy: .public)")
            return lim
        } catch {
            logger.warning("fetchLimit decode failed, using default: \(String(describing: error), privacy: .public)")
            return .default
        }
    }

    func fetchList(userId: Int) async throws -> [PrivateMedia] {
        let data = try await APIClient.shared.post("/api/payPrivateMsg/privateInfo",
                                                    body: ["userId": userId])
        let list = PrivateMediaDecoder.decodeList(from: data)
        logger.info("fetchList ok count=\(list.count, privacy: .public)")
        return list
    }

    func save(ops: [PrivateMediaOp]) async throws {
        // ops 是 Encodable —— 转 [Any] 走 arrayBody 加密链路（对齐 H5 `http.post(path, arrayData)`）
        let jsonData = try JSONEncoder().encode(ops)
        guard let arr = try JSONSerialization.jsonObject(with: jsonData) as? [Any] else {
            throw APIError(code: "-1", message: "save ops encode failed")
        }
        _ = try await APIClient.shared.post("/api/payPrivateMsg/uploadPrivateInfo", arrayBody: arr)
        logger.info("save ok ops=\(ops.count, privacy: .public)")
    }

    func decryptVideoUrl(originalUrl: String) async throws -> String {
        let fileUrl = Self.extractFileUrl(from: originalUrl)
        // spec §1.3 H5 两入口字段名分叉：主流程 secretSettings 用 `searchValue`
        do {
            return try await callDecrypt(field: "searchValue", value: fileUrl)
        } catch let apiError as APIError where Self.authErrorCodes.contains(apiError.code) {
            // step 3 反悔 #10 S1：auth 类失效（1004 挤下线 / 1005 token 失效）不 fallback
            // —— spec §R-20 fallback 语义是字段名 400，越权覆盖 auth 会翻倍 SessionInvalidated 通知
            throw apiError
        } catch {
            logger.warning("decrypt searchValue failed, fallback to 'search': \(String(describing: error), privacy: .public)")
            return try await callDecrypt(field: "search", value: fileUrl)
        }
    }

    /// APIClient 层已经对 1004/1005 全局 post `.apiSessionInvalidated`，业务层再 fallback 会翻倍通知
    private static let authErrorCodes: Set<String> = ["1004", "1005"]

    private func callDecrypt(field: String, value: String) async throws -> String {
        let data = try await APIClient.shared.post("/sts/getPrivateOssUploadParam",
                                                    body: [field: value])
        let param = try JSONDecoder().decode(PrivateOssParam.self, from: data)
        // H5 拼装：`{cdnUrl}/{fileUrl}?{authorizationParam}`
        return "\(param.cdnUrl)/\(value)?\(param.authorizationParam)"
    }

    func fetchGifts() async throws -> [GiftMessageItem] {
        // H5 secretSettings/index.vue:309 `<GiftsPopup type="IM" ...>` → IM 场景
        let all = try await GiftService.getGiftList(scene: .im)
        return all.map { g in
            GiftMessageItem(
                id: String(g.id),
                name: g.name,
                iconUrl: g.giftSmallImg.isEmpty ? g.giftImg : g.giftSmallImg,
                price: Int(g.giftPrice)
            )
        }
    }

    // MARK: - Helpers

    /// 从 videoUrl（完整 URL 形式）提取 OSS object key。
    /// H5 主流程：`URL(url).pathname.substring(1)`（去掉前导 /）
    static func extractFileUrl(from originalUrl: String) -> String {
        if let u = URL(string: originalUrl) {
            let path = u.path
            return path.hasPrefix("/") ? String(path.dropFirst()) : path
        }
        // 兜底：last path component（uploadVideo.vue: `url.split('/').pop()`）
        if let range = originalUrl.range(of: "/", options: .backwards) {
            return String(originalUrl[range.upperBound...])
        }
        return originalUrl
    }
}

/// H-2 业务错误。真实现留一个占位保留（Store 单测里被引用）。
enum GiftMessageServiceError: Error, LocalizedError {
    case stubNotImplemented                     // 保留：单测/Preview 使用
    case unsupportedVideoFormat(String)         // R-16：扩展名不在白名单
    case videoTooLarge(sizeBytes: Int)          // R-17：>50MB
    case invalidVideoFile                       // 视频文件读取失败

    var errorDescription: String? {
        switch self {
        case .stubNotImplemented:
            return "GiftMessageService stub: not yet implemented"
        case .unsupportedVideoFormat(let ext):
            return "Unsupported video format: \(ext)"
        case .videoTooLarge(let bytes):
            return "Video too large: \(bytes / 1024 / 1024) MB"
        case .invalidVideoFile:
            return "Invalid video file"
        }
    }
}
