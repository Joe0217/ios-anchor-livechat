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
            let raw = String(data: data, encoding: .utf8)?.prefix(500) ?? "<非文本>"
            logger.error("getUserLevel decode failed: \(String(describing: error)) | raw=\(raw)")
            throw error
        }
    }
}
