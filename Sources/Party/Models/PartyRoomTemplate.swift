import Foundation

/// 房间模板（`room/getRoomTempList` 返回的 `List<PartyRoomMode>`）。
/// 模板决定麦位布局：语聊位与视频位的数量、位置、最大上麦数。
/// MVP 至少需要 dev 后端配置一个**混合模板**（含 1 视频位 + 多语聊位），见 §1.5 #8 阻塞。
struct PartyRoomTemplate: Codable, Equatable, Identifiable {
    let id: Int
    let name: String?
    let modeType: Int?           // 安卓字段名待 implement 期对照接口返回
    let seatCount: Int?          // 总麦位数
    let videoSeatCount: Int?     // 视频位数（含接待位）
    let voiceSeatCount: Int?     // 语聊位数
    let coverImage: String?
}
