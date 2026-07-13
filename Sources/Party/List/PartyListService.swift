import Foundation

/// 派对房大厅列表数据层桥接协议（E 期 Step 1a）。
///
/// - Live 实现见 `PartyListServiceLive`（依赖 `PartyAPI`，不进 HilyTests 白名单）
/// - 单测/Preview 用 `PartyListServicePreviewFake`（pure Swift 零 SDK 依赖）
///
/// **参数透传**（spec §7, F-11）：与 `PartyAPI.roomList` 完全对齐，MVP 不用 snapshotId（F-03）
/// 但保留 languageCode/queryParam/version 以便 F 期加搜索/关注时无 breaking change。
protocol PartyListService: Sendable {
    /// 3 tab（Party/Follow/Recent）共用契约；kind 决定 endpoint（对齐 H5 用户端）。
    func fetchList(
        kind: PartyRoomListKind,
        languageCode: String?,
        offset: Int?,
        pageSize: Int,
        queryParam: String?,
        version: String
    ) async throws -> [PartyRoomInfo]
}

// MARK: - PreviewFake（enum-driven，spec §7 F-24）

/// 单测/Preview 用可编程 Fake。
///
/// 每次调用返回下一个 `Kind`（如列表耗尽则重复最后一个），支持模拟：
/// - 正常成功 / 空列表 / 延迟 / 网络错 / decode 错 / 业务码错
///
/// **不含调用记录**——单测断言走 Store state 而非 service 调用参数；如需断言参数请用 `FakePartyListService` (Tests target 内可编程记录版)。
struct PartyListServicePreviewFake: PartyListService {
    enum Kind: Sendable {
        case success([PartyRoomInfo])
        case empty
        case delayThenSuccess([PartyRoomInfo], delayNanos: UInt64)
        case networkError
        case decodeError
        case businessError(code: String, message: String)
    }

    let kinds: [Kind]

    init(_ kind: Kind) {
        self.kinds = [kind]
    }

    init(sequence: [Kind]) {
        self.kinds = sequence
    }

    func fetchList(
        kind: PartyRoomListKind,
        languageCode: String?,
        offset: Int?,
        pageSize: Int,
        queryParam: String?,
        version: String
    ) async throws -> [PartyRoomInfo] {
        // 按 offset 索引下一个 kind（PreviewFake.Kind，不同于外层 PartyRoomListKind）
        let idx = min(max(0, (offset ?? 0) / max(1, pageSize)), kinds.count - 1)
        let kind = kinds[idx]

        switch kind {
        case .success(let rooms):
            return rooms
        case .empty:
            return []
        case .delayThenSuccess(let rooms, let delay):
            try await Task.sleep(nanoseconds: delay)
            try Task.checkCancellation()
            return rooms
        case .networkError:
            throw PartyListServicePreviewFakeError.networkError
        case .decodeError:
            throw PartyListServicePreviewFakeError.decodeError
        case .businessError(let code, let message):
            throw PartyListServicePreviewFakeError.businessError(code: code, message: message)
        }
    }
}

/// PreviewFake 错误类型（模拟真实 `PartyAPIError` 的分类）。
enum PartyListServicePreviewFakeError: Error, Equatable, Sendable {
    case networkError
    case decodeError
    case businessError(code: String, message: String)
}
