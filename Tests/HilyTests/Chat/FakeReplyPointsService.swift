import Foundation

/// H-3 ReplyPointsService 测试 Fake（对齐 FakeP2PChatProvider / FakeEditProfileService 模式）。
@MainActor
final class FakeReplyPointsService: ReplyPointsServiceProtocol {

    // MARK: - Stub 出参（默认成功空数据）

    var stubMessageBoxList: Result<MessageBoxList, Error> = .success(MessageBoxList(pointInfoList: [], anchorPoint: 0))
    var stubClaimDiamond: Result<Int, Error> = .success(0)
    var stubSettleResult: Result<SettleReplyPointsResult, Error> = .success(
        SettleReplyPointsResult(settled: false, points: 0, multiplier: 1, basePoints: 0, currentTotalPoints: 0, message: nil)
    )
    var stubRecords: Result<[MessageBoxRecordItem], Error> = .success([])

    // MARK: - 调用记录

    private(set) var fetchMessageBoxListCalls: [String] = []
    private(set) var claimCalls: [String] = []
    private(set) var settleCalls: [(userYxAccid: String, userMsgId: String, msgType: String)] = []
    private(set) var fetchRecordsCalls: [String] = []

    // MARK: - Protocol

    func fetchMessageBoxList(userYxAccid: String) async throws -> MessageBoxList {
        fetchMessageBoxListCalls.append(userYxAccid)
        return try stubMessageBoxList.get()
    }

    func claimTreasureBox(userYxAccid: String) async throws -> Int {
        claimCalls.append(userYxAccid)
        return try stubClaimDiamond.get()
    }

    func settleReplyPoints(userYxAccid: String, userMsgId: String, msgType: String) async throws -> SettleReplyPointsResult {
        settleCalls.append((userYxAccid, userMsgId, msgType))
        return try stubSettleResult.get()
    }

    func fetchMessageBoxRecords(userYxAccid: String) async throws -> [MessageBoxRecordItem] {
        fetchRecordsCalls.append(userYxAccid)
        return try stubRecords.get()
    }
}

/// H-3 ReplyPointsConfigBridge 测试 Fake（用 class 便于测试中动态改字段模拟 loaded 状态转移）
@MainActor
final class FakeReplyPointsConfigBridge: ReplyPointsConfigBridging {
    var isLoaded: Bool
    var payMsgPoints: Int?
    var freeMsgPoints: Int?

    init(isLoaded: Bool = true, pay: Int? = 5, free: Int? = 1) {
        self.isLoaded = isLoaded
        self.payMsgPoints = pay
        self.freeMsgPoints = free
    }
}

/// 单测常用文案 fixture（对齐 spec §6.5 L10n key）
enum FakeReplyPointsTipTexts {
    static let all = ReplyPointsTipTexts(
        guide: "guide-text",
        stimulate: "stimulate-text",
        replyPointGuide: "reply-fast-text",
        replyRemind: "reply-remind-text"
    )
}
