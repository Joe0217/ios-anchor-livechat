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
            // 解码失败时打印原始 JSON 便于排错（字段类型/名称不匹配最常见）。
            // P2-17：响应体含 PII（nickname/age/相册 URL/giftList），privacy:.private 防
            // 进 sysdiagnose / USB Console 截图泄漏；截短到 120 字节足够定位 schema 不匹配。
            let raw = String(data: data.prefix(120), encoding: .utf8) ?? "<非文本>"
            logger.error("getAnchorInfo decode failed: \(String(describing: error), privacy: .private) | raw=\(raw, privacy: .private)")
            throw error
        }
    }

    /// 2026-07-16 删除：`getMineInfo` / `getMineInfoRaw`（对应 `/api/user/getUserInfo`）后端不存在（返 404）。
    /// 对齐 H5 蓝本 `stores/modules/user.js:74-131 loginSuccess(res) → setMineInfo(res)`——登录响应本身即为 mine
    /// 权威来源，无独立"我的信息"接口。主播扩展字段（level/callPrice/picList/...）由 `/api/anchor/userInfo`
    /// 补齐到 `info`。

    /// 主播礼物墙（H5 mine/index.vue:92-98 独立于 getAnchorInfo 拉取）。
    /// 后端字段：`giftId` + `giftImg||icon` + `giftName` + `giftCount||num`；GiftItem 已双兼容。
    /// 接口: POST `/api/anchor/getGiftWallList`（H5 src/api/profile/index.ts:27）；body 空对象。
    static func getGiftWallList() async throws -> [GiftItem] {
        let data = try await APIClient.shared.post("/api/anchor/getGiftWallList")
        do {
            let list = try JSONDecoder().decode([GiftItem].self, from: data)
            logger.info("getGiftWallList decoded count=\(list.count)")
            return list
        } catch {
            let raw = String(data: data.prefix(200), encoding: .utf8) ?? "<非文本>"
            logger.error("getGiftWallList decode failed: \(String(describing: error), privacy: .private) | raw=\(raw, privacy: .private)")
            throw error
        }
    }
}
