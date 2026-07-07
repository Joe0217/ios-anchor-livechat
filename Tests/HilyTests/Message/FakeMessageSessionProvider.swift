import Combine
import Foundation

/// HilyTests 用 Fake（Step 1a）。
/// - `fetchAll` / `setStickTop` / `delete` 结果由 `stub*` 字段控制
/// - `subscribe` 保存 handler，测试通过 `emit(_:)` 手动触发事件
@MainActor
final class FakeMessageSessionProvider: MessageSessionProviderProtocol {

    // MARK: - Stubs

    var stubSessions: Result<[MessageSession], Error> = .success([])
    var stubStickTop: Result<Void, Error> = .success(())
    var stubDelete: Result<Void, Error> = .success(())

    // MARK: - Suspend hook（R-3-a 精确复现 loading 期间事件入队）

    /// 若 true，`fetchAll` 会挂起等 `resumeFetch()` 显式释放（测试用）
    var fetchSuspends: Bool = false
    private var fetchResumeHandle: CheckedContinuation<Void, Never>?

    func resumeFetch() {
        fetchResumeHandle?.resume()
        fetchResumeHandle = nil
    }

    // MARK: - Spy

    private(set) var stickTopCalls: [(sessionId: String, isTop: Bool)] = []
    private(set) var deleteCalls: [String] = []

    // MARK: - Delegate handler

    private var handler: (@MainActor (MessageSessionEvent) -> Void)?

    func emit(_ event: MessageSessionEvent) {
        handler?(event)
    }

    // MARK: - Protocol

    func fetchAll() async throws -> [MessageSession] {
        if fetchSuspends {
            await withCheckedContinuation { cont in
                fetchResumeHandle = cont
            }
        }
        return try stubSessions.get()
    }

    func setStickTop(sessionId: String, isTop: Bool) async throws {
        stickTopCalls.append((sessionId, isTop))
        try stubStickTop.get()
    }

    func delete(sessionId: String) async throws {
        deleteCalls.append(sessionId)
        try stubDelete.get()
    }

    func subscribe(_ handler: @MainActor @escaping (MessageSessionEvent) -> Void) {
        self.handler = handler
    }

    func unsubscribe() {
        self.handler = nil
    }

    // MARK: - IM 连接态（Step 3 反悔 #1）

    /// **默认 false**：避免 Store init 内 sink 自动 fire load 污染现有测试
    /// （现有 R-1/R-3/R-4 用例都 `await store.load()` 显式驱动）；
    /// R-8 用例显式 emit false→true 复现 IM 登录延迟场景
    let connectionStateSubject = CurrentValueSubject<Bool, Never>(false)

    var isConnectedPublisher: AnyPublisher<Bool, Never> {
        connectionStateSubject.eraseToAnyPublisher()
    }
}

@MainActor
final class FakePrimeLevelProvider: PrimeLevelProviderProtocol {
    var stubPrime: Set<String> = []
    private(set) var fetchCalls: [[String]] = []

    func fetchPrime(yxAccIds: [String]) async -> Set<String> {
        fetchCalls.append(yxAccIds)
        // 仅返回请求 uid 与 stub 的交集，避免测试误伤
        return stubPrime.intersection(yxAccIds)
    }
}

// MARK: - v4 系统消息 3 入口 Fakes

@MainActor
final class FakeStationListProvider: StationListProviderProtocol {
    var stubLatest: StationMail?
    var stubIsUnread: Bool = false
    private(set) var markReadCalls: [String] = []

    func fetchLatest() async -> StationMail? { stubLatest }
    func isUnread(_ mail: StationMail) -> Bool { stubIsUnread }
    func markRead(_ mail: StationMail) { markReadCalls.append(mail.id) }
}

@MainActor
final class FakeConversationProfileProvider: ConversationProfileProviderProtocol {
    var stubProfiles: [String: ConversationProfile] = [:]
    private(set) var fetchCalls: [[String]] = []
    func fetch(yxAccIds: [String]) async -> [String: ConversationProfile] {
        fetchCalls.append(yxAccIds)
        var out: [String: ConversationProfile] = [:]
        for id in yxAccIds { if let p = stubProfiles[id] { out[id] = p } }
        return out
    }
}

@MainActor
final class FakeCustomerServiceIdStore: CustomerServiceIdProviderProtocol {
    private let subject = CurrentValueSubject<String?, Never>(nil)

    var customerYxAccId: String? { subject.value }
    var customerYxAccIdPublisher: AnyPublisher<String?, Never> { subject.eraseToAnyPublisher() }

    /// 测试用：直接设置值并 fire publisher
    func set(_ id: String?) { subject.send(id) }

    func refreshIfNeeded() async { /* no-op */ }
    func clear() { subject.send(nil) }
}

// MARK: - Test data factory

enum MessageSessionFactory {
    static func make(id: String,
                     nickname: String = "peer",
                     timestamp: Int64 = 0,
                     unread: Int = 0,
                     isTop: Bool = false,
                     ext: MessageSessionExt = .empty) -> MessageSession {
        MessageSession(id: id, peerNickname: nickname, peerAvatarURL: nil,
                       lastMessage: "hi", lastMessageTimestamp: timestamp,
                       unreadCount: unread, isTop: isTop, ext: ext)
    }
}

// MARK: - Test error

enum FakeError: Error, Equatable {
    case network
    case sdk
}
