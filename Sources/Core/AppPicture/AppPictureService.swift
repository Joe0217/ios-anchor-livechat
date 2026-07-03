import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "AppPictureService")

/// 全局图片配置数据层。
///
/// 对齐 H5 `stores/modules/home.js:437 getBannerList(params)`，接口 path
/// `POST /api/index/v4/getAppPicByType`（H5 `src/api/home/index.ts:45`）。
/// 参数是 type 数字数组（H5 `homeStore.getBannerList([2])`）。
///
/// 响应 envelope 解密后 result 形如 `{"2": [item, ...], "1": [...]}` —— key 是 type 字符串。
final class AppPictureService: AppPictureServiceProtocol {

    static let shared = AppPictureService()

    private init() {}

    func fetchPictures(types: [AppPictureType]) async throws -> [AppPictureType: [AppPictureItem]] {
        let body: [Any] = types.map { $0.rawValue }
        let data = try await APIClient.shared.post("/api/index/v4/getAppPicByType", arrayBody: body)
        return Self.decodeGroup(from: data)
    }

    /// 解析形如 `{"2": [item, ...]}` 的 dict。key 缺失或非 dict 时返回空。
    static func decodeGroup(from data: Data) -> [AppPictureType: [AppPictureItem]] {
        if String(data: data, encoding: .utf8) == "null" {
            return [:]
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let dict = raw as? [String: Any]
        else {
            let preview = String(data: data.prefix(120), encoding: .utf8) ?? "<binary>"
            logger.warning("decodeGroup: cannot parse, bytes=\(data.count, privacy: .public) preview=\(preview, privacy: .private)")
            return [:]
        }
        var result: [AppPictureType: [AppPictureItem]] = [:]
        for (key, value) in dict {
            guard let typeInt = Int(key), let type = AppPictureType(rawValue: typeInt) else { continue }
            guard let arr = value as? [[String: Any]] else { continue }
            result[type] = arr.compactMap(AppPictureItem.init(from:))
        }
        return result
    }
}
