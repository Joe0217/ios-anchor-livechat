import Foundation

protocol RobotCallServing {
    func respond(to invite: RobotCallInvite, answered: Bool) async throws
    func finish(recordId: String) async throws
}

struct RobotCallService: RobotCallServing {
    func respond(to invite: RobotCallInvite, answered: Bool) async throws {
        let body: [String: Any] = [
            "isAnswered": answered ? 1 : 0,
            "videoId": invite.videoId,
            "recordId": invite.recordId
        ]
        _ = try await APIClient.shared.post("/api/homeTraffic/hostCallVirtualUser", body: body)
    }

    func finish(recordId: String) async throws {
        _ = try await APIClient.shared.post(
            "/api/homeTraffic/hostCallOverVirtualUser",
            body: ["recordId": recordId]
        )
    }
}
