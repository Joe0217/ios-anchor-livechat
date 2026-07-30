import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "LotteryService")

/// 当前活动抽奖 API。所有端点均来自现行 H5 `api/lottery/index.js` 的真实调用，
/// 走主 APIClient 的 AES 鉴权通道；不复用历史 Android `expand/turntableGame/*` 轮询契约。
protocol LotteryServicing {
    func fetchActivity(activityID: String) async throws -> LotteryActivity
    func draw(activityID: String, mode: LotteryDrawMode, sourceURL: String) async throws -> [LotteryPrize]
    func fetchRecords(activityID: String, page: Int, pageSize: Int) async throws -> LotteryRecordPage
    func fetchWinners(activityID: String) async throws -> [LotteryRewardRecord]
    func fetchRoomID(for target: LotteryRoomTarget) async throws -> String?
}

struct LotteryServiceReal: LotteryServicing {
    func fetchActivity(activityID: String) async throws -> LotteryActivity {
        let data = try await APIClient.shared.post(
            "/api/lottery/findLotteryActivity",
            body: ["activityId": activityID]
        )
        return try JSONDecoder().decode(LotteryActivityPayload.self, from: data).activity
    }

    func draw(activityID: String, mode: LotteryDrawMode, sourceURL: String) async throws -> [LotteryPrize] {
        // 独立抽奖页不依赖 Party 房：H5 在非房间入口也发送空 room context，后端可正常结算。
        let data = try await APIClient.shared.post(
            "/api/lottery/userLottery",
            body: [
                "activityId": activityID,
                "lotteryType": mode.rawValue,
                "roomId": "",
                "roomType": "",
                "url": sourceURL
            ]
        )
        let result = try JSONDecoder().decode(LotteryDrawPayload.self, from: data)
        guard !result.prizes.isEmpty else {
            throw LotteryServiceError.emptyDrawResult
        }
        return result.prizes
    }

    func fetchRecords(activityID: String, page: Int, pageSize: Int) async throws -> LotteryRecordPage {
        let data = try await APIClient.shared.post(
            "/api/lottery/findLotteryActivityUser",
            body: [
                "activityId": activityID,
                "currentPage": page,
                "pageSize": pageSize
            ]
        )
        return try JSONDecoder().decode(LotteryRecordPayload.self, from: data).page
    }

    func fetchWinners(activityID: String) async throws -> [LotteryRewardRecord] {
        let data = try await APIClient.shared.post(
            "/api/lottery/findLotteryActivityReward",
            body: ["activityId": activityID]
        )
        return try JSONDecoder().decode(LotteryRewardListPayload.self, from: data).records
    }

    func fetchRoomID(for target: LotteryRoomTarget) async throws -> String? {
        let data = try await APIClient.shared.post(
            "/api/lottery/getRoomId",
            body: ["roomType": target.rawValue]
        )
        let roomID = try JSONDecoder().decode(LotteryRoomIDPayload.self, from: data).roomID
        logger.debug(
            "Lottery getRoomId roomType=\(target.rawValue, privacy: .public) roomId=\(roomID ?? "<empty>", privacy: .private)"
        )
        return roomID
    }
}

enum LotteryServiceError: LocalizedError {
    case emptyDrawResult

    var errorDescription: String? {
        switch self {
        case .emptyDrawResult:
            return L10n.Lottery.noPrizeReturned
        }
    }
}

private struct LotteryActivityPayload: Decodable {
    let activity: LotteryActivity

    enum CodingKeys: String, CodingKey {
        case activityInfo, prizeList, lotteryImgList, userTotalTimes, pointProgress, popupConfig
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let info = (try? container.decodeIfPresent(LotteryActivityInfo.self, forKey: .activityInfo)) ?? .empty
        let prizes = (try? container.decodeIfPresent([LotteryPrize].self, forKey: .prizeList)) ?? []
        let images = (try? container.decodeIfPresent([LotteryImage].self, forKey: .lotteryImgList)) ?? []
        let userTotalTimes = container.decodeFlexibleInt(forKey: .userTotalTimes) ?? 0
        let pointProgress = (try? container.decodeIfPresent(LotteryPointProgress.self, forKey: .pointProgress)) ?? .empty
        let popupConfiguration = try? container.decodeIfPresent(LotteryPopupConfiguration.self, forKey: .popupConfig)

        activity = LotteryActivity(
            info: info,
            prizes: prizes,
            assets: LotteryAssets(images: images),
            userTotalTimes: max(0, userTotalTimes),
            pointProgress: pointProgress,
            popupConfiguration: popupConfiguration
        )
    }
}

private struct LotteryDrawPayload: Decodable {
    let prizes: [LotteryPrize]

    enum CodingKeys: String, CodingKey { case prizeList }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prizes = (try? container.decodeIfPresent([LotteryPrize].self, forKey: .prizeList)) ?? []
    }
}

struct LotteryRecordPage: Equatable {
    let records: [LotteryRewardRecord]
    let remainingTimes: Int?
}

private struct LotteryRecordPayload: Decodable {
    let page: LotteryRecordPage

    enum CodingKeys: String, CodingKey { case rewardList, userTotalTimes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        page = LotteryRecordPage(
            records: (try? container.decodeIfPresent([LotteryRewardRecord].self, forKey: .rewardList)) ?? [],
            remainingTimes: container.decodeFlexibleInt(forKey: .userTotalTimes)
        )
    }
}

private struct LotteryRewardListPayload: Decodable {
    let records: [LotteryRewardRecord]

    enum CodingKeys: String, CodingKey { case rewardList }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = (try? container.decodeIfPresent([LotteryRewardRecord].self, forKey: .rewardList)) ?? []
        if records.isEmpty {
            logger.debug("Lottery winners response is empty")
        }
    }
}

/// `roomId` 在不同环境会以 String 或 JSON number 返回；统一收敛为非空 String。
struct LotteryRoomIDPayload: Decodable {
    let roomID: String?

    enum CodingKeys: String, CodingKey {
        case roomID = "roomId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = container.decodeFlexibleString(forKey: .roomID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        roomID = decoded?.isEmpty == false ? decoded : nil
    }
}
