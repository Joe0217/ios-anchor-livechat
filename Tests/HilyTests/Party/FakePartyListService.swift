import Foundation

/// 可编程 Fake：记录调用参数 + 支持"多页/异常/延迟"序列。
///
/// 与 `PartyListServicePreviewFake`（source 侧）区别：
/// - 本 Fake 用于**单测断言参数**（如 offset/languageCode）
/// - `PartyListServicePreviewFake` 用于 Preview（无调用记录、Sendable struct）
final class FakePartyListService: PartyListService, @unchecked Sendable {

    // MARK: - 可编程序列

    enum Response {
        case success([PartyRoomInfo])
        case delayThenSuccess([PartyRoomInfo], delayNanos: UInt64)
        /// 模拟底层请求不响应父 Task 取消；Store 仍必须靠取消检查/数据代际丢弃迟到结果。
        case uncancellableDelayThenSuccess([PartyRoomInfo], delayNanos: UInt64)
        case throwing(Error)
    }

    /// 按调用次序返回；越界则用最后一个（模拟稳定后续响应）
    var responses: [Response] = []

    // MARK: - 调用记录

    struct Call: Equatable {
        let kind: PartyRoomListKind
        let languageCode: String?
        let offset: Int?
        let pageSize: Int
        let queryParam: String?
        let version: String
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    // MARK: - PartyListService

    func fetchList(
        kind: PartyRoomListKind,
        languageCode: String?,
        offset: Int?,
        pageSize: Int,
        queryParam: String?,
        version: String
    ) async throws -> [PartyRoomInfo] {
        lock.lock()
        _calls.append(Call(
            kind: kind,
            languageCode: languageCode,
            offset: offset,
            pageSize: pageSize,
            queryParam: queryParam,
            version: version
        ))
        let idx = min(_calls.count - 1, responses.count - 1)
        let resp = idx >= 0 && !responses.isEmpty ? responses[idx] : Response.success([])
        lock.unlock()

        switch resp {
        case .success(let rooms):
            return rooms
        case .delayThenSuccess(let rooms, let delay):
            try await Task.sleep(nanoseconds: delay)
            try Task.checkCancellation()
            return rooms
        case .uncancellableDelayThenSuccess(let rooms, let delay):
            let task = Task.detached {
                try? await Task.sleep(nanoseconds: delay)
                return rooms
            }
            return await task.value
        case .throwing(let error):
            throw error
        }
    }
}

actor FakePartyMyRoomProvider {
    enum Response {
        case value(PartyMyRoomInfoWrapper?)
        case uncancellableDelayThenValue(PartyMyRoomInfoWrapper?, delayNanos: UInt64)
    }

    private var responses: [Response]
    private(set) var callCount = 0

    init(responses: [Response]) {
        self.responses = responses
    }

    func fetch() async -> PartyMyRoomInfoWrapper? {
        let index = min(callCount, max(0, responses.count - 1))
        callCount += 1
        guard !responses.isEmpty else { return nil }
        switch responses[index] {
        case .value(let value):
            return value
        case .uncancellableDelayThenValue(let value, let delayNanos):
            return await Task.detached {
                try? await Task.sleep(nanoseconds: delayNanos)
                return value
            }.value
        }
    }
}

// MARK: - PartyRoomInfo mock helper（测试专用，最小字段构造）

extension PartyRoomInfo {
    /// 测试用最小构造。所有字段都是 Optional，只对断言相关的少数字段赋值。
    static func mock(
        id: String,
        roomName: String? = nil,
        onlineUsers: Int = 0,
        lockFlag: Int? = nil,
        needPassword: Bool? = nil
    ) -> PartyRoomInfo {
        var dict: [String: Any] = ["id": id]
        if let roomName { dict["roomName"] = roomName }
        if let lockFlag { dict["lockFlag"] = lockFlag }
        if let needPassword { dict["needPassword"] = needPassword }
        if onlineUsers > 0 {
            dict["onlineUserList"] = (0..<onlineUsers).map { ["userId": "u\($0)"] }
        }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(PartyRoomInfo.self, from: data)
    }
}
