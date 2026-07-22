import Foundation

/// sapi 实现，对齐主播 H5 `apiDislikeBullet`。
final class PaidBulletServiceReal: PaidBulletService, @unchecked Sendable {
    private static let dislikePath = "/sapi/weidou/v1/client/party/bullet/dislike"

    func dislike(billId: String) async throws -> PaidBulletDislikeResponse {
        let data = try await PartyAPIClient.shared.post(
            Self.dislikePath,
            body: ["billId": billId],
            suppressCodes: ["*"]
        )
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 后端允许 result=null；点踩成功不依赖返回字段。
            return PaidBulletDislikeResponse()
        }
        return PaidBulletDislikeResponse(
            dislikeCount: PaidBulletQueue.integer(object["dislikeCount"]),
            muted: PaidBulletQueue.bool(object["muted"])
        )
    }
}
