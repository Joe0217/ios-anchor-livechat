import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "MatchService")

// MARK: - 数据层 protocol

/// L 里程碑：视频匹配数据层 protocol。单测注入 Fake；真集成走 `MatchService.shared`。
///
/// 对齐 H5 `src/api/match/index.ts` 4 接口（MVP 排除 `matchFaceViolationReport` + robot 相关）。
/// 详见 `docs/plan/L-spec-视频匹配Match-*.md` §3.1。
protocol MatchServiceProtocol {
    /// `POST /api/match/pool/isOpen` —— 前置校验能否开启（返 1=可开 / 2=人脸失败 / 3=超次数）。
    func isMatchOpen() async throws -> MatchCanOpenResult

    /// `POST /api/match/pool/open` —— 开/关匹配池。
    /// - parameter status: 1=开启 / 0=关闭
    /// - parameter faceCheckStatus: 人脸检测失败时上报 1；MVP 阶段人脸抽检未做，恒 nil
    /// - returns: true=后端接受（返 1）；false=后端拒绝或异常
    func toggleMatch(status: Int, faceCheckStatus: Int?) async throws -> Bool

    /// `POST /api/anchor/getMatchPoolData` —— Match tab 首屏数据（跑马灯 + 用户列表）。
    func loadMatchPoolData() async throws -> MatchPoolData

    /// `POST /api/match/pool/matchList` —— 匹配池用户列表分页。
    /// - parameter pageNum: 1-based 页码
    /// - parameter pageSize: 单页条数（H5 常用 20）
    func loadMatchList(pageNum: Int, pageSize: Int) async throws -> [MatchUserItem]
}

// MARK: - 真集成实现

/// 视频匹配数据层实现。走主 `APIClient`（AES-128-CBC / Base64 上行 / Hex 下行 / envelope）。
///
/// **body 精确性**：spec §7 open #2 明示 body 待 step 1c grep H5 `stores/modules/*.js` 校验。
/// 本骨架按 H5 `src/api/match/index.ts` 签名对齐；实际 body 可能带额外字段（如 platform / version）。
final class MatchService: MatchServiceProtocol {

    static let shared = MatchService()

    private init() {}

    func isMatchOpen() async throws -> MatchCanOpenResult {
        // H5: getMatchCanOpen = (data: any) => http.post('/api/match/pool/isOpen', data)
        // step 1c 前假设：无 body（H5 c-goMatch.vue:324 调用点无 arg）
        let data = try await APIClient.shared.post("/api/match/pool/isOpen", body: [:])
        let value = Self.decodeInt(from: data)
        guard let result = MatchCanOpenResult(rawValue: value) else {
            logger.warning("isMatchOpen: unknown int value=\(value) fallback to .allowed")
            return .allowed
        }
        logger.info("isMatchOpen result=\(value)")
        return result
    }

    func toggleMatch(status: Int, faceCheckStatus: Int?) async throws -> Bool {
        // H5: toggleMatch = (data: any) => http.post('/api/match/pool/open', data)
        var body: [String: Any] = ["status": status]
        if let fs = faceCheckStatus { body["faceCheckStatus"] = fs }
        let data = try await APIClient.shared.post("/api/match/pool/open", body: body)
        let value = Self.decodeInt(from: data)
        logger.info("toggleMatch status=\(status) fs=\(faceCheckStatus ?? -1) result=\(value)")
        return value == 1
    }

    func loadMatchPoolData() async throws -> MatchPoolData {
        // H5: getMatchRecordList = (data: any) => http.post('/api/anchor/getMatchPoolData', data)
        // step 1c 前假设：无 body（H5 home/match.vue:19 调用点无 arg）
        let data = try await APIClient.shared.post("/api/anchor/getMatchPoolData", body: [:])
        let pool = try Self.decodePoolData(from: data)
        logger.info("loadMatchPoolData: callList=\(pool.callList.count) userList=\(pool.userList.count)")
        return pool
    }

    func loadMatchList(pageNum: Int, pageSize: Int) async throws -> [MatchUserItem] {
        // H5: getMatchList = (data: Pagination) => http.post('/api/match/pool/matchList', data)
        let body: [String: Any] = ["pageNum": pageNum, "pageSize": pageSize]
        let data = try await APIClient.shared.post("/api/match/pool/matchList", body: body)
        let items = Self.decodeUserList(from: data)
        logger.info("loadMatchList pageNum=\(pageNum) got=\(items.count)")
        return items
    }

    // MARK: - Decode helpers

    /// 解密后的响应可能是 Int 数字（1/2/3），也可能是 JSON `{"result": 1}` 或字符串 `"1"`。多路 fallback。
    static func decodeInt(from data: Data) -> Int {
        if let s = String(data: data, encoding: .utf8) {
            let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t\""))
            if let i = Int(trimmed) { return i }
        }
        if let n = try? JSONDecoder().decode(Int.self, from: data) { return n }
        if let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let v = dict["result"] as? Int { return v }
            if let s = dict["result"] as? String, let i = Int(s) { return i }
        }
        logger.warning("decodeInt: cannot parse response, bytes=\(data.count)")
        return 0
    }

    /// 匹配池数据 3 路 fallback：直接 struct / wrapped in `{result: ...}` / 空 null。
    static func decodePoolData(from data: Data) throws -> MatchPoolData {
        if String(data: data, encoding: .utf8) == "null" {
            return MatchPoolData(callList: [], userList: [])
        }
        let decoder = JSONDecoder()
        if let pool = try? decoder.decode(MatchPoolData.self, from: data) {
            return pool
        }
        // fallback: {"result": {"callList": [...], "userList": [...]}}
        if let wrapped = try? decoder.decode([String: MatchPoolData].self, from: data),
           let inner = wrapped["result"] {
            return inner
        }
        throw MatchServiceError.decodeFailed(bytes: data.count)
    }

    /// 匹配用户列表 3 路 fallback：数组 / wrapped / null。
    static func decodeUserList(from data: Data) -> [MatchUserItem] {
        if String(data: data, encoding: .utf8) == "null" { return [] }
        let decoder = JSONDecoder()
        if let arr = try? decoder.decode([MatchUserItem].self, from: data) { return arr }
        if let wrapped = try? decoder.decode([String: [MatchUserItem]].self, from: data) {
            for key in ["list", "rows", "data", "items", "result"] {
                if let list = wrapped[key] { return list }
            }
        }
        logger.warning("decodeUserList: cannot parse, bytes=\(data.count)")
        return []
    }
}

// MARK: - Errors

enum MatchServiceError: Error, Equatable {
    case decodeFailed(bytes: Int)
    case unexpectedResponse
}

// MARK: - MatchPoolData 便利 init（用于 fallback null 场景）

extension MatchPoolData {
    init(callList: [MatchCallRecord], userList: [MatchUserItem]) {
        self.callList = callList
        self.userList = userList
    }
}
