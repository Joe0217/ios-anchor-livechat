import Foundation
import os

/// NIM 自定义消息 payload 解析工具集（H 里程碑 spec §4.1）。
///
/// 从 `PartyRoomChatManager.unwrapDataField` (L370-406) 提取的通用 helper；
/// 直播 / 派对房 / sysMsg 各通道收消息后调用本 API 把 `data` 字段三态归一为业务字典。
///
/// **三态解析**（H 校验清单 §1.1.3 / 安卓 §3.0）：
/// 1. 对象 / Dictionary：caller 直传 `Map`/`[String: Any]` → 直接返回
/// 2. JSON 字符串：caller 用 `JSON.toJSONString` 包过 → 二次 parse
/// 3. Base64(gzip) 字符串：通常用于派对房 1001 / 2049 / 1100-1112 大 payload
///    判 magic `0x1f8b` 后 gzip 解压；异常退化为纯 Base64（无 gzip 容器）
///
/// **依赖**：仅 `Foundation` + `GzipDecompressor`（纯 Compression）+ `os.Logger`；
/// 不引 `NIMSDK`，可加入 `HilyTests` target 单测验证三态。
enum NIMPayloadDecoder {

    private static let logger = Logger(subsystem: "com.anchor.livechat", category: "nim-payload")

    /// 解析 NIM `remoteExt["data"]` 字段，返回业务字典。
    ///
    /// - Parameter raw: NIM 透传的 `data` 字段值（可能是 dict / JSON 字符串 / Base64+gzip / nil）
    /// - Returns: 业务字典；nil 表示解析失败（caller 决定如何降级）
    static func unwrapDataField(_ raw: Any?) -> [String: Any]? {
        // 1) 已是字典
        if let dict = raw as? [String: Any] {
            return dict
        }

        guard let s = raw as? String, !s.isEmpty else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespaces)

        // 2) JSON 字符串
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            guard let jsonData = trimmed.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any]
        }

        // 3) Base64 + 可选 gzip
        guard let bytes = Data(base64Encoded: trimmed) else {
            logger.notice("unwrapDataField: invalid base64 raw")
            return nil
        }
        let jsonBytes: Data
        if bytes.count >= 2, bytes[0] == 0x1f, bytes[1] == 0x8b {
            // gzip 容器（magic 0x1f 0x8b）
            do {
                jsonBytes = try GzipDecompressor.decompress(bytes)
            } catch {
                logger.error("unwrapDataField: gzip decompress failed \(String(describing: error), privacy: .public)")
                return nil
            }
        } else {
            // 退化：纯 Base64 无 gzip
            jsonBytes = bytes
        }
        return (try? JSONSerialization.jsonObject(with: jsonBytes)) as? [String: Any]
    }

    /// 便利封装：从 `remoteExt` 字典中提取 `data` 字段并解三态。
    /// 直播 / 派对房 chatroomMsg 入口共用。
    static func unwrapDataField(from ext: [String: Any]) -> [String: Any]? {
        unwrapDataField(ext["data"])
    }
}
