import Foundation
// 注：HilyTests target 直接编译纯 Swift 源文件 (project.yml 配置)，
// CircleServiceProtocol / MomentPage / MomentPost 与本文件同 module，无需 import。

/// 单测用 mock，实现 `CircleServiceProtocol`。
///
/// 用法（典型）：
/// ```
/// let fake = FakeCircleService()
/// fake.getAllMomentsResult = .success(MomentPage(posts: [...], currentPage: 1, hasMore: true))
/// let store = MomentFeedStore(service: fake, pageSize: 20)
/// ```
final class FakeCircleService: CircleServiceProtocol {

    // 注入结果
    var getMyMomentsResult: Result<MomentPage, Error> = .success(.empty)
    var getAllMomentsResult: Result<MomentPage, Error> = .success(.empty)
    var getOfficialMomentsResult: Result<MomentPage, Error> = .success(.empty)
    var likeResult: Result<Void, Error> = .success(())
    var getCommentsResult: Result<[MomentComment], Error> = .success([])

    // 调用记录
    private(set) var getMyMomentsCalls: [(userId: Int, pageSize: Int, currentPage: Int)] = []
    private(set) var getAllMomentsCalls: [(pageSize: Int, currentPage: Int)] = []
    private(set) var getOfficialMomentsCalls: [(pageSize: Int, currentPage: Int)] = []
    private(set) var likeCalls: [(postId: Int, optionType: Int)] = []
    private(set) var getCommentsCalls: [(postId: Int, pageSize: Int, currentPage: Int)] = []

    /// 模拟网络延迟 (秒)，让单测可在 cancel/再触发期窗口内插桩
    var delaySeconds: Double = 0

    func getMyMoments(userId: Int, pageSize: Int, currentPage: Int) async throws -> MomentPage {
        getMyMomentsCalls.append((userId, pageSize, currentPage))
        try await maybeSleep()
        switch getMyMomentsResult {
        case .success(let page): return page
        case .failure(let err): throw err
        }
    }

    func getAllMoments(pageSize: Int, currentPage: Int) async throws -> MomentPage {
        getAllMomentsCalls.append((pageSize, currentPage))
        try await maybeSleep()
        switch getAllMomentsResult {
        case .success(let page): return page
        case .failure(let err): throw err
        }
    }

    func getOfficialMoments(pageSize: Int, currentPage: Int) async throws -> MomentPage {
        getOfficialMomentsCalls.append((pageSize, currentPage))
        try await maybeSleep()
        switch getOfficialMomentsResult {
        case .success(let page): return page
        case .failure(let err): throw err
        }
    }

    func like(postId: Int, optionType: Int) async throws {
        likeCalls.append((postId, optionType))
        try await maybeSleep()
        switch likeResult {
        case .success: return
        case .failure(let err): throw err
        }
    }

    func getComments(postId: Int, pageSize: Int, currentPage: Int) async throws -> [MomentComment] {
        getCommentsCalls.append((postId, pageSize, currentPage))
        try await maybeSleep()
        switch getCommentsResult {
        case .success(let list): return list
        case .failure(let err): throw err
        }
    }

    private func maybeSleep() async throws {
        if delaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }
    }
}

/// 测试用通用错误
enum TestError: Error, Equatable {
    case timeout
    case offline
    case server(code: String)
}

/// 测试用 MomentPost 构造器
enum TestPostFactory {
    static func make(postId: Int,
                     likeFlag: Int? = 0,
                     likeCount: Int? = 0,
                     commentCount: Int? = 0) -> MomentPost {
        // 使用 JSON 解码绕过 init (Codable struct 字段较多)
        let dict: [String: Any] = [
            "id": postId,
            "likeFlag": likeFlag ?? NSNull(),
            "likeNum": likeCount ?? NSNull(),
            "commentNum": commentCount ?? NSNull(),
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict.compactMapValues { $0 is NSNull ? nil : $0 })
        return try! JSONDecoder().decode(MomentPost.self, from: data)
    }
}
