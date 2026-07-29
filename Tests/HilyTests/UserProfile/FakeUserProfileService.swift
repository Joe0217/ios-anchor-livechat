import Foundation

// HilyTests target 直接编译纯 Swift 源文件（project.yml 配置），
// UserProfileServiceProtocol / UserDetail 与本文件同 module，无需 import。

/// 单测用 mock，实现 `UserProfileServiceProtocol`。
///
/// 用法：
/// ```
/// let fake = FakeUserProfileService()
/// fake.fetchResult = .success(.fixture(userId: "100"))
/// let vm = UserProfileViewModel(userId: "100", service: fake)
/// await vm.loadDetail()
/// XCTAssertEqual(vm.detail?.userId, "100")
/// ```
final class FakeUserProfileService: UserProfileServiceProtocol {

    // 注入结果
    var fetchResult: Result<UserDetail, Error> = .success(.fixture())
    var followResult: Result<Void, Error> = .success(())
    var blockResult: Result<Void, Error> = .success(())

    // 调用记录
    private(set) var fetchCalls: [Int] = []
    private(set) var followCalls: [FollowUserRequest] = []
    private(set) var blockCalls: [BlockUserRequest] = []

    /// 模拟网络延迟，用于并发/cancel 测试
    var delaySeconds: Double = 0

    func fetchDetail(userId: Int) async throws -> UserDetail {
        fetchCalls.append(userId)
        try await maybeSleep()
        switch fetchResult {
        case .success(let d): return d
        case .failure(let err): throw err
        }
    }

    func follow(request: FollowUserRequest) async throws {
        followCalls.append(request)
        try await maybeSleep()
        switch followResult {
        case .success: return
        case .failure(let err): throw err
        }
    }

    func block(request: BlockUserRequest) async throws {
        blockCalls.append(request)
        try await maybeSleep()
        switch blockResult {
        case .success: return
        case .failure(let err): throw err
        }
    }

    private func maybeSleep() async throws {
        guard delaySeconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
    }
}

// MARK: - fixture 工厂

extension UserDetail {
    /// 测试 fixture 最小字段。
    static func fixture(userId: String = "100001",
                       nickname: String = "Alice",
                       icon: String? = nil,
                       gender: Int? = 2,
                       age: Int? = 24,
                       countryId: String? = "US",
                       connRate: String? = "85%",
                       yxAccid: String? = "yx_100001",
                       followed: Bool = false,
                       isBlocked: Int? = nil,
                       like: Int = 100,
                       favorite: Int = 50,
                       giftList: [Gift] = [],
                       guardianList: [UserGuardianAnchor] = []) -> UserDetail {
        UserDetail(
            userId: userId,
            nickname: nickname,
            icon: icon,
            gender: gender,
            age: age,
            countryId: countryId,
            connRate: connRate,
            yxAccid: yxAccid,
            followed: followed,
            isBlocked: isBlocked,
            like: like,
            favorite: favorite,
            giftList: giftList,
            guardianList: guardianList
        )
    }
}

// MARK: - stub 错误

struct UserProfileStubError: Error, LocalizedError {
    let kind: String
    var errorDescription: String? { "stub: \(kind)" }
}
