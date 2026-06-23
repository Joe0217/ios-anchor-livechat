import Foundation
import os

/// 1v1 通话相关接口（对应 H5 src/api/call/index.ts）。
///
/// 接口路径与 H5 一致；密钥/加解密走 APIClient.shared，无需在此处理。
/// happy path 必需的 4 个端点：createCall / joinCall / callRate / callOver；
/// 其余（apiBeginCall/callDeductionFee/missCall/callEvaluation）按路线图 §三 C
/// 不在 C 范围（H5 也已废 apiBeginCall），暂不接入。
enum CallService {

    // MARK: - 主叫：创建通话

    /// POST /api/call/record/v2/createCall —— 主叫发起，后端分配 channelId 并返回对方资料。
    /// H5 useCallApi.handleCallOutFunc:`{beCallUserId: <number>, callType: <stringEnum>}`。
    /// 失败抛 APIError（1111 "current status unable to make a call" 通常是主播在线态字段
    /// 不对，确保 WSHeartbeat 上报 CALL_END）。
    static func createCall(beCallUserId: Int,
                           callType: CallFrontGameType = .direct) async throws -> CreateCallResult {
        let body: [String: Any] = [
            "beCallUserId": beCallUserId,                  // 与 H5 一致传 number
            "callType": String(callType.rawValue),         // CALL_GAME_TYPE_NUMBER 是字符串枚举
        ]
        let data = try await APIClient.shared.post("/api/call/record/v2/createCall", body: body)
        return try JSONDecoder().decode(CreateCallResult.self, from: data)
    }

    // MARK: - 被叫：拉对方资料（3s 超时）

    /// POST /api/call/record/v2/joinCall —— 被叫收到 RTM VideoCall 后调用，拉对方资料填充 UI。
    /// 用 Task + withThrowingTaskGroup 实现 3s 超时（H5 用 Promise.race），
    /// 超时即抛错让 CallStore 把状态归零，不阻塞用户挂断。
    static func joinCall(channelId: String) async throws -> JoinCallResult {
        let body: [String: Any] = ["searchValue": channelId]
        return try await withTimeout(seconds: CallTuning.joinCallTimeoutSeconds) {
            let data = try await APIClient.shared.post("/api/call/record/v2/joinCall", body: body)
            return try JSONDecoder().decode(JoinCallResult.self, from: data)
        }
    }

    // MARK: - 通话结束

    /// POST /api/call/callOver —— 端侧主动挂断时调用，上报结束原因（CallOverReason 1-11）。
    /// 即使失败也不影响本地 UI 复位（CallStore 已先重置），日志即可。
    static func callOver(channelId: String, overReason: CallOverReason) async {
        let body: [String: Any] = [
            "channelId": channelId,
            "overReason": overReason.rawValue,
        ]
        do {
            _ = try await APIClient.shared.post("/api/call/callOver", body: body)
        } catch let e as APIError {
            AppLogger.call.notice("⚠️ [CallService] callOver 失败 channel=\(channelId, privacy: .public) reason=\(overReason.rawValue, privacy: .public) code=\(e.code, privacy: .public) msg=\(e.message, privacy: .private)")
        } catch {
            AppLogger.call.notice("⚠️ [CallService] callOver 异常 channel=\(channelId, privacy: .public) error=\(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - 接通率上报（四节点）

    /// POST /api/call/callRate —— 接听率统计上报。answered/rejected/timeout/canceled 各调一次。
    /// 本端为主播，userType 默认 .anchor；callType（主/被叫）由调用方传。
    /// C 范围只保留调用入口，业务层是否真发由 CallStore 控制（默认不发，留给 implement 阶段补开关）。
    static func callRate(channelId: String,
                         callType: CallRateType,
                         category: CallRateCategory,
                         answerTime: Int,
                         userType: CallRateUserType = .anchor,
                         abnormal: Int = 0) async {
        let body: [String: Any] = [
            "channelId": channelId,
            "callType": callType.rawValue,
            "category": category.rawValue,
            "answerTime": answerTime,
            "userType": userType.rawValue,
            "abnormal": abnormal,
        ]
        do {
            _ = try await APIClient.shared.post("/api/call/callRate", body: body)
        } catch let e as APIError {
            AppLogger.call.notice("⚠️ [CallService] callRate 失败 channel=\(channelId, privacy: .public) cat=\(category.rawValue, privacy: .public) code=\(e.code, privacy: .public) msg=\(e.message, privacy: .private)")
        } catch {
            AppLogger.call.notice("⚠️ [CallService] callRate 异常 error=\(error.localizedDescription, privacy: .private)")
        }
    }
}

// MARK: - 通用超时包装
//
// Swift Structured Concurrency 没自带 timeout，用 TaskGroup 让"业务 task"和"睡眠 task"
// 同时跑，谁先返回用谁；睡眠先到则抛 CallTimeout 让上层归零。
private struct CallTimeoutError: LocalizedError {
    let seconds: TimeInterval
    // 自定义 Error 必须 conform LocalizedError + 实现 errorDescription 才能让外部
    // `error.localizedDescription` 拿到自定义文案，否则会落到默认 "<module>.CallTimeoutError"。
    var errorDescription: String? { "操作超时（\(Int(seconds))s）" }
}

private func withTimeout<T: Sendable>(seconds: TimeInterval,
                                      operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CallTimeoutError(seconds: seconds)
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}
