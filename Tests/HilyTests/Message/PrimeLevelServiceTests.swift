import XCTest

/// H-1 spec §3.3 反向 R-2 + Codable 边界（Step 1c 单测）。
@MainActor
final class PrimeLevelServiceTests: XCTestCase {

    // MARK: - R-2: 分批 ≤50

    func test_prime_batch_split_50() async {
        var receivedBatchSizes: [Int] = []
        let service = PrimeLevelService(batchFetcher: { ids in
            receivedBatchSizes.append(ids.count)
            return ids   // 全返 Prime
        }, batchSize: 50)

        // 120 uid → 应分 3 批：50 / 50 / 20
        let uids = (1...120).map { "u\($0)" }
        let result = await service.fetchPrime(yxAccIds: uids)

        XCTAssertEqual(receivedBatchSizes, [50, 50, 20], "120 uid 应分 3 批 50/50/20")
        XCTAssertEqual(result.count, 120, "全批成功应收到全部 uid")
    }

    func test_prime_batch_size_lt_batchSize_single_call() async {
        var callCount = 0
        let service = PrimeLevelService(batchFetcher: { ids in
            callCount += 1
            return ids
        }, batchSize: 50)

        let result = await service.fetchPrime(yxAccIds: ["u1", "u2"])
        XCTAssertEqual(callCount, 1, "单批调用")
        XCTAssertEqual(result, ["u1", "u2"])
    }

    // MARK: - R-2: 部分批失败，其他批照常

    func test_prime_partial_batch_failure_others_ok() async {
        var callIdx = 0
        let service = PrimeLevelService(batchFetcher: { ids in
            callIdx += 1
            if callIdx == 2 { throw FakeError.network }   // 第 2 批失败
            return ids
        }, batchSize: 50)

        let uids = (1...120).map { "u\($0)" }   // 3 批：50/50/20
        let result = await service.fetchPrime(yxAccIds: uids)

        // 第 1 批 u1-u50 + 第 3 批 u101-u120 应在结果里；第 2 批 u51-u100 丢失
        XCTAssertEqual(result.count, 70, "70 = 50 (第 1 批) + 20 (第 3 批)")
        XCTAssertTrue(result.contains("u1"))
        XCTAssertTrue(result.contains("u120"))
        XCTAssertFalse(result.contains("u75"), "第 2 批失败的 uid 不应进结果")
    }

    // MARK: - 全批失败 → 空集（Store 层 R-1 fallback）

    func test_prime_all_batches_failure_returns_empty() async {
        let service = PrimeLevelService(batchFetcher: { _ in
            throw FakeError.network
        }, batchSize: 50)

        let result = await service.fetchPrime(yxAccIds: (1...20).map { "u\($0)" })
        XCTAssertEqual(result, [], "全批失败应返回空 Set，触发 Store 层 R-1 fallback")
    }

    // MARK: - 边界

    func test_prime_empty_input_short_circuit_no_call() async {
        var callCount = 0
        let service = PrimeLevelService(batchFetcher: { _ in
            callCount += 1
            return []
        }, batchSize: 50)

        let result = await service.fetchPrime(yxAccIds: [])
        XCTAssertEqual(callCount, 0, "空输入应短路不发请求")
        XCTAssertEqual(result, [])
    }
}

// MARK: - Codable 边界（v3 契约：top-level [String] 数组，非 {result:[...]} 包装）

final class PrimeLevelResponseTests: XCTestCase {

    func test_decode_top_level_array_returns_prime_uids() throws {
        let json = #"["u1","u2","u3"]"#.data(using: .utf8)!
        let resp = try JSONDecoder().decode(PrimeLevelResponse.self, from: json)
        XCTAssertEqual(resp.result, ["u1", "u2", "u3"])
    }

    func test_decode_empty_top_level_array() throws {
        let json = #"[]"#.data(using: .utf8)!
        let resp = try JSONDecoder().decode(PrimeLevelResponse.self, from: json)
        XCTAssertEqual(resp.result, [])
    }

    /// 防字段类型偷换：后端可能把 top-level 从 array 改成 dict/string/null，容错归空集不抛
    func test_decode_wrong_top_level_type_returns_empty() throws {
        let jsonDict = #"{"result":["u1"]}"#.data(using: .utf8)!
        let respDict = try JSONDecoder().decode(PrimeLevelResponse.self, from: jsonDict)
        XCTAssertEqual(respDict.result, [], "top-level 是 dict 时应容错归空集")

        let jsonStr = #""not an array""#.data(using: .utf8)!
        let respStr = try JSONDecoder().decode(PrimeLevelResponse.self, from: jsonStr)
        XCTAssertEqual(respStr.result, [], "top-level 是 string 时应容错归空集")

        let jsonNull = #"null"#.data(using: .utf8)!
        let respNull = try JSONDecoder().decode(PrimeLevelResponse.self, from: jsonNull)
        XCTAssertEqual(respNull.result, [], "top-level null 应容错归空集")
    }
}

// MARK: - Array batched 分批 helper

final class ArrayBatchedTests: XCTestCase {

    func test_batched_120_into_50() {
        let sizes = (1...120).map { "u\($0)" }.batched(into: 50).map(\.count)
        XCTAssertEqual(sizes, [50, 50, 20])
    }

    func test_batched_50_into_50_yields_one_batch() {
        let sizes = (1...50).map { "u\($0)" }.batched(into: 50).map(\.count)
        XCTAssertEqual(sizes, [50])
    }

    func test_batched_empty_returns_empty() {
        let batches: [[String]] = [].batched(into: 50)
        XCTAssertTrue(batches.isEmpty)
    }

    func test_batched_smaller_than_size_single_batch() {
        let sizes = ["a", "b"].batched(into: 50).map(\.count)
        XCTAssertEqual(sizes, [2])
    }
}
