import Foundation

// HilyTests target 直接编译纯 Swift 源文件（project.yml 配置），
// BlocklistServiceProtocol / BlocklistItem 与本文件同 module，无需 import。

/// 单测用 mock，实现 `BlocklistServiceProtocol`。
///
/// 用法（典型）：
/// ```
/// let fake = FakeBlocklistService()
/// fake.fetchResult = .success([item1, item2])
/// let vm = BlocklistViewModel(service: fake, pageSize: 20)
/// await vm.loadFirstPage()
/// XCTAssertEqual(vm.items.count, 2)
/// ```
final class FakeBlocklistService: BlocklistServiceProtocol {

    // 注入结果
    var fetchResult: Result<[BlocklistItem], Error> = .success([])
    var removeResult: Result<Void, Error> = .success(())

    /// 多页时按 page 注入不同结果；优先于 `fetchResult`。
    /// key=page, value=Result。命中则用 page 结果；未命中回退 fetchResult。
    var fetchPageResults: [Int: Result<[BlocklistItem], Error>] = [:]

    // 调用记录
    private(set) var fetchCalls: [(page: Int, size: Int)] = []
    private(set) var removeCalls: [BlockOptRequest] = []

    /// 模拟网络延迟（秒），让单测可在 cancel/再触发期窗口内插桩
    var delaySeconds: Double = 0

    func fetchActive(page: Int, size: Int) async throws -> [BlocklistItem] {
        fetchCalls.append((page, size))
        try await maybeSleep()
        let r = fetchPageResults[page] ?? fetchResult
        switch r {
        case .success(let arr): return arr
        case .failure(let err): throw err
        }
    }

    func removeBlock(request: BlockOptRequest) async throws {
        removeCalls.append(request)
        try await maybeSleep()
        switch removeResult {
        case .success: return
        case .failure(let err): throw err
        }
    }

    private func maybeSleep() async throws {
        guard delaySeconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
    }
}

// MARK: - 测试 fixture 工厂

extension BlocklistItem {
    /// 构造测试用条目的最少必填字段。
    static func fixture(userId: String = "100001",
                       nickname: String = "Alice",
                       yxAccid: String = "yx_100001",
                       createTimeMs: Int64? = 1_700_000_000_000) -> BlocklistItem {
        BlocklistItem(
            userId: userId,
            nickname: nickname,
            icon: nil,
            countryId: nil,
            age: nil,
            yxAccid: yxAccid,
            gender: nil,
            userType: nil,
            createTimeMs: createTimeMs
        )
    }
}

// MARK: - 测试 stub 错误

/// 测试专用错误（避免在测试代码里依赖真 APIError 复杂结构，但仍可断言）
struct StubNetworkError: Error, LocalizedError {
    let kind: String
    var errorDescription: String? { "stub: \(kind)" }
}
