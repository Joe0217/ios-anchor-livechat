import Foundation

/// H-3 Step 1a-4：TranslateService / CheckPrivateInfoService 测试 Fake（Store 集成层 Step 1a-5 用）。
///
/// **@MainActor class 自动 Sendable**；conform nonisolated protocol methods 时，方法体
/// 隐式 @MainActor-isolated（caller 用 `await` 已经跨 actor 处理）。
@MainActor
final class FakeTranslateService: TranslateServiceProtocol {
    var stubResult: Result<String, Error> = .success("translated")
    private(set) var calls: [(text: String, targetLang: String, key: String, area: String)] = []

    func translate(text: String, targetLang: String, key: String, area: String) async throws -> String {
        calls.append((text, targetLang, key, area))
        return try stubResult.get()
    }
}

@MainActor
final class FakeCheckPrivateInfoService: CheckPrivateInfoServiceProtocol {
    var stubResult: Result<[String: PrivateLockStatus], Error> = .success([:])
    private(set) var calls: [(userId: String, privateIds: [String])] = []

    func checkPrivateInfo(userId: String, privateIds: [String]) async throws -> [String: PrivateLockStatus] {
        calls.append((userId, privateIds))
        return try stubResult.get()
    }
}

@MainActor
final class FakeSendPrivateInfoService: SendPrivateInfoServiceProtocol {
    var stubResult: Result<[String: Any], Error> = .success(["privateId": "p-1", "giftId": 100])
    private(set) var calls: [(peerUserId: String, privateId: String)] = []

    func fetchSignedData(peerUserId: String, privateId: String) async throws -> [String: Any] {
        calls.append((peerUserId, privateId))
        return try stubResult.get()
    }
}
