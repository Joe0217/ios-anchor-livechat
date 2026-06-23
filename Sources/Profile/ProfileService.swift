import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "ProfileService")

/// 主播个人中心相关接口（对应 H5 src/api/anchor + src/api/user）。
/// 请求头里的 loginToken 由 APIClient 自动附带。
///
/// 接口蓝本：`docs/plan/iOS重建-功能梳理-20260616/modules/09-账号设置与基建.md` §243-268。
/// 字段含义遇分歧时**信源码不信文档**（CLAUDE.md「实现纪律」），先拿 raw 字典调试再固化 Codable。
enum ProfileService {

    /// 主播详情（核心接口）。返回原始字典，便于实测看字段含义后再固化模型。
    static func getAnchorInfoRaw() async throws -> [String: Any] {
        let data = try await APIClient.shared.post("/api/anchor/userInfo")
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// 主播详情：Codable 解码版本。字段名与 `AnchorInfo` 不符的部分会落 nil，
    /// 调试期建议同时调 `getAnchorInfoRaw` 看原始字段。
    static func getAnchorInfo() async throws -> AnchorInfo {
        let data = try await APIClient.shared.post("/api/anchor/userInfo")
        do {
            let info = try JSONDecoder().decode(AnchorInfo.self, from: data)
            logger.info("getAnchorInfo decoded userId=\(info.userId ?? -1) nickname=\(info.nickname ?? "nil")")
            return info
        } catch {
            // 解码失败时打印原始 JSON 便于排错（字段类型/名称不匹配最常见）
            let raw = String(data: data, encoding: .utf8)?.prefix(500) ?? "<非文本>"
            logger.error("getAnchorInfo decode failed: \(String(describing: error)) | raw=\(raw)")
            throw error
        }
    }

    /// 我的基础信息（蓝本 09 §256）。H5 `getMineInfo`，与 getAnchorInfo 字段大量重叠
    /// 但侧重点不同：mineInfo 给通用字段（nickname/icon/age/sex/country），
    /// anchorInfo 给主播专属（callPrice/相册/审核态）。两者并发拉取互补。
    /// 返回模型复用 AnchorInfo（字段全 Optional 兼容缺失）。
    static func getMineInfo() async throws -> AnchorInfo {
        let data = try await APIClient.shared.post("/api/user/getUserInfo")
        do {
            let info = try JSONDecoder().decode(AnchorInfo.self, from: data)
            logger.info("getMineInfo decoded userId=\(info.userId ?? -1) nickname=\(info.nickname ?? "nil")")
            return info
        } catch {
            let raw = String(data: data, encoding: .utf8)?.prefix(500) ?? "<非文本>"
            logger.error("getMineInfo decode failed: \(String(describing: error)) | raw=\(raw)")
            throw error
        }
    }

    static func getMineInfoRaw() async throws -> [String: Any] {
        let data = try await APIClient.shared.post("/api/user/getUserInfo")
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
