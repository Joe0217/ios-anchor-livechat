import Foundation

/// H-3 私密消息发送前置签发接口（spec §1.1.7 / Critical-2）。
///
/// **对齐 H5** `chat/index.vue:624-630`：
/// ```js
/// data = await getSendPrivateInfo({userId: otherInfo.value.userId, privateId: item.id})
/// data.userId = otherInfo.value.userId
/// ext = JSON.stringify({data, extensionType: 'privateMsg'})
/// ```
///
/// **入参**：`{userId: 对端 userId, privateId: item.id}` —— 对端 userId 反直觉但对齐 H5（后端据此扣费/签名）
/// **返回**：后端签发的 `data` dict（字段列表 S1 spike）—— 前端 spread 到 remoteExt.privateMsg.data 后覆盖 3 字段
protocol SendPrivateInfoServiceProtocol: Sendable {
    func fetchSignedData(peerUserId: String, privateId: String) async throws -> [String: Any]
}

struct SendPrivateInfoHTTPService: SendPrivateInfoServiceProtocol, Sendable {
    static let shared = SendPrivateInfoHTTPService()

    func fetchSignedData(peerUserId: String, privateId: String) async throws -> [String: Any] {
        let data = try await APIClient.shared.post(
            "/api/payPrivateMsg/sendPrivateInfo",
            body: ["userId": peerUserId, "privateId": privateId]
        )
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SendPrivateInfoError.invalidResponse
        }
        return dict
    }
}

enum SendPrivateInfoError: Error, Equatable {
    case invalidResponse
}

/// H-3 私聊内选私密消息发送参数（P2PChatStore.sendPrivateImage/Video 入参）。
///
/// **来源**：`GiftMessageService.fetchList(userId: mine.userId)` 返 `[PrivateMedia]`；
/// ChatDetailContainer 层做 `PrivateMedia → PrivateMediaSelection` 转换（避免 Chat 跨依赖 Work/GiftMessage）。
struct PrivateMediaSelection: Equatable, Hashable {
    let privateId: String          // ext.data.privateId
    let iconType: Int              // 1=图片 / 2=视频
    let url: URL                   // media url（图片/视频通用）
    let coverUrl: URL?             // 视频封面；图片 nil
    let dur: Int?                  // 视频时长秒；图片 nil

    var isVideo: Bool { iconType == 2 }
}
