import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "LiveContribution")

/// 直播间钻石收益 store（对齐 H5 `liveStore.currentLiveIncome`）
///
/// **触发链**（H5 蓝本）：
/// - 进房：`userJoinRoom` API 拉取初始值
/// - 收礼：NIM attachType 50 消息到达 → 重新调 `getCurrentLiveIncome()` 拉当前值（后端已算好，不本地累加）
///
/// **无定时轮询**（仅事件驱动）
@MainActor
final class LiveContributionStore: ObservableObject {
    @Published private(set) var currentLiveIncome: Int64 = 0
    /// 主态默认取当前登录主播；客态进房时改为被观看主播，避免把自己的直播收入渲染到他人房间。
    private var anchorUserId: String?

    func configure(anchorUserId: String) {
        self.anchorUserId = anchorUserId.isEmpty ? nil : anchorUserId
        currentLiveIncome = 0
    }

    /// 进房初始化拉取
    func loadInitial() {
        Task { await refresh() }
    }

    /// v14 真 API：对齐 H5 `getCurrentLiveIncome`（src/stores/modules/live.js:61-68）
    ///
    /// - endpoint: `POST /api/agora/live/getRoomAndJoinRoom`
    /// - body: `{ searchValue: <主播自己的 userId> }`
    /// - response: `currentLiveIncome` 字段（后端算好的当场累计钻石）
    ///
    /// **H5 调用时机**：
    /// - 进房 `logined()` 回调后（live.js:180）
    /// - 收 attachType 50 礼物消息后 `handleLiveGiftMessage` 内再次调（live.js:840）
    ///
    /// iOS 对齐：LiveRoomView.onAppear → loadInitial → refresh()；
    /// NIMChatroomManager processIncoming 收 attachType 50 → refresh() 重拉
    func refresh() async {
        let uid = anchorUserId ?? SessionStore.shared.user?.userId.map(String.init)
        guard let uid, !uid.isEmpty else {
            logger.warning("Contribution refresh skipped: no session userId")
            return
        }
        do {
            let body: [String: Any] = ["searchValue": uid]
            let data = try await APIClient.shared.post("/api/agora/live/getRoomAndJoinRoom", body: body)
            let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            // response.currentLiveIncome 多态解析（Int64/Int/NSNumber）
            var income: Int64 = 0
            if let v = dict["currentLiveIncome"] as? Int64 { income = v }
            else if let v = dict["currentLiveIncome"] as? Int { income = Int64(v) }
            else if let v = dict["currentLiveIncome"] as? NSNumber { income = v.int64Value }
            currentLiveIncome = income
            logger.info("Contribution refreshed from API: \(income, privacy: .public)")
        } catch let e as APIError {
            logger.error("Contribution refresh APIError code=\(e.code, privacy: .public) msg=\(e.message, privacy: .public)")
        } catch {
            logger.error("Contribution refresh error: \(String(describing: error), privacy: .public)")
        }
    }

    /// v12 收礼后累加真实钻石（对齐 H5 `handleLiveGiftMessage` 消息里的 giftPrice × giftNum）
    ///
    /// **H5 真实语义**：礼物消息到达后调 API 重拉后端算好的累计值。
    /// **iOS Fakes 阶段替代方案**：直接用消息里的 `giftPrice × giftNum` 本地累加 —— 视觉与真实收礼节奏一致
    ///
    /// - Parameter diamonds: 本次礼物贡献值（`payload.data.giftPrice × giftNum`）
    func apply(diamonds: Int64) {
        guard diamonds > 0 else { return }
        currentLiveIncome += diamonds
        logger.info("Contribution +\(diamonds, privacy: .public) → \(self.currentLiveIncome, privacy: .public)")
    }

    /// v13 直接覆盖当前值（对齐 H5 收 attachType 50 后调 getCurrentLiveIncome API 拉后端权威值）
    ///
    /// Fakes 阶段替代：attachType 50 消息 msg[] 里主播自己的 cost 即后端算好的当场累计
    /// 直接 assign 避免和 apply(diamonds:) 双重累加漂移
    func setCurrent(_ value: Int64) {
        guard value >= 0, value != currentLiveIncome else { return }
        currentLiveIncome = value
        logger.info("Contribution set to \(value, privacy: .public) (from server-computed total)")
    }

    /// logout / 离房清理
    func clear() {
        currentLiveIncome = 0
        anchorUserId = nil
    }
}
