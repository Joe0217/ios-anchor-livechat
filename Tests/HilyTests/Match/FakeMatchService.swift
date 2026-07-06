import Foundation

/// L 里程碑 Match 单测：可编程 Fake service。
///
/// 每个方法的返回值/异常独立配置；调用记录用于断言调用次数、顺序、参数。
final class FakeMatchService: MatchServiceProtocol {

    // MARK: - 可配置返回值

    var isMatchOpenResult: Result<MatchCanOpenResult, Error> = .success(.allowed)
    var toggleMatchResult: Result<Bool, Error> = .success(true)
    var matchPoolDataResult: Result<MatchPoolData, Error> = .success(MatchPoolData(callList: [], userList: []))
    var matchListResult: Result<[MatchUserItem], Error> = .success([])

    // MARK: - 调用记录

    private(set) var isMatchOpenCallCount = 0
    private(set) var toggleMatchCalls: [(status: Int, faceCheckStatus: Int?)] = []
    private(set) var loadPoolDataCallCount = 0
    private(set) var loadMatchListCalls: [(pageNum: Int, pageSize: Int)] = []

    // MARK: - MatchServiceProtocol

    func isMatchOpen() async throws -> MatchCanOpenResult {
        isMatchOpenCallCount += 1
        return try isMatchOpenResult.get()
    }

    func toggleMatch(status: Int, faceCheckStatus: Int?) async throws -> Bool {
        toggleMatchCalls.append((status, faceCheckStatus))
        return try toggleMatchResult.get()
    }

    func loadMatchPoolData() async throws -> MatchPoolData {
        loadPoolDataCallCount += 1
        return try matchPoolDataResult.get()
    }

    func loadMatchList(pageNum: Int, pageSize: Int) async throws -> [MatchUserItem] {
        loadMatchListCalls.append((pageNum, pageSize))
        return try matchListResult.get()
    }
}

// 通用测试错误 `TestError` 在 FakeCircleService.swift 定义（同 test target，直接复用 .offline / .timeout / .server）
