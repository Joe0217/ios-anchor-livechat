import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "LevelService")

/// 段位接口（蓝本 09 §277）。
enum LevelService {

    /// `POST /api/user/level/v2/userLevel`：本人当前段位详情。
    /// 接口无 body 参数（与 getAnchorInfo 同模式）；后端按 token 识别用户。
    static func getUserLevel() async throws -> LevelInfo {
        let data = try await APIClient.shared.post("/api/user/level/v2/userLevel")
        do {
            return try JSONDecoder().decode(LevelInfo.self, from: data)
        } catch {
            // P2-17：响应体含等级 / 经验值等用户字段，privacy:.private + 截短到 120 字节
            let raw = String(data: data.prefix(120), encoding: .utf8) ?? "<非文本>"
            logger.error("getUserLevel decode failed: \(String(describing: error), privacy: .private) | raw=\(raw, privacy: .private)")
            throw error
        }
    }
}
