import Foundation

/// 付费跑马灯主播端点踩接口。
///
/// 接口按登录态确定主播身份，客户端只传弹幕账单 ID。服务端负责本房校验和幂等。
protocol PaidBulletService: Sendable {
    func dislike(billId: String) async throws -> PaidBulletDislikeResponse
}

struct PaidBulletDislikeResponse: Equatable {
    let dislikeCount: Int?
    let muted: Bool?

    init(dislikeCount: Int? = nil, muted: Bool? = nil) {
        self.dislikeCount = dislikeCount
        self.muted = muted
    }
}
