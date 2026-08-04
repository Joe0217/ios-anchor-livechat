import XCTest
import Combine

/// 覆盖 spec §5 Bridge 层 F-1 ~ F-10 + deny-by-default + snapshot/@Published 一致性 + userType 变化重算。
/// 见 [P-plan-用户权限管理系统-*.md] Task 3。
final class SelfPermissionBridgeTests: XCTestCase {

    // MARK: - Helper

    private func makeBridge() -> (SelfPermissionBridge, CurrentValueSubject<PermissionSessionState, Never>) {
        let sessionSubject = CurrentValueSubject<PermissionSessionState, Never>(.loggedOut)
        let bridge = SelfPermissionBridge(
            sessionPublisher: sessionSubject.eraseToAnyPublisher()
        )
        return (bridge, sessionSubject)
    }

    private func sendSession(
        userType: Int?,
        authenticated: Bool = true,
        to subject: CurrentValueSubject<PermissionSessionState, Never>
    ) {
        subject.send(PermissionSessionState(userType: userType, isAuthenticated: authenticated))
    }

    /// 等 sink 双写完成（同步 lock + async MainActor Task）
    private func waitForSink() {
        let exp = expectation(description: "sink propagated")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
    }

    // MARK: - Deny-by-default · loaded=false 全 false

    func test_notLoaded_allCanXFalse() {
        let (bridge, session) = makeBridge()
        sendSession(userType: 2, authenticated: false, to: session) // 合法 userType 但未登录
        waitForSink()

        XCTAssertFalse(bridge.canCallSnapshot, "loaded=false 时 deny-by-default")
        XCTAssertFalse(bridge.canLiveSnapshot)
        XCTAssertFalse(bridge.canPartySnapshot)
    }

    // MARK: - F-1 ~ F-3: 合法 userType

    func test_userType_2_allCanXTrue() {
        let (bridge, session) = makeBridge()
        sendSession(userType: 2, to: session)
        waitForSink()

        XCTAssertTrue(bridge.canCallSnapshot)
        XCTAssertTrue(bridge.canLiveSnapshot)
        XCTAssertTrue(bridge.canPartySnapshot)
        for feature in PermissionFeature.allCases {
            XCTAssertTrue(bridge.canUseSnapshot(feature), "userType 2 should allow \(String(describing: feature))")
        }
    }

    func test_userType_9_allCanXTrue() {
        let (bridge, session) = makeBridge()
        sendSession(userType: 9, to: session)
        waitForSink()

        XCTAssertTrue(bridge.canCallSnapshot)
        XCTAssertTrue(bridge.canLiveSnapshot)
        XCTAssertTrue(bridge.canPartySnapshot)
    }

    // MARK: - F-4 ~ F-9: 六种黑名单 userType

    func test_userType_101_blocksCall() {
        let (bridge, session) = makeBridge()
        sendSession(userType: 101, to: session); waitForSink()
        XCTAssertFalse(bridge.canCallSnapshot)
        XCTAssertTrue(bridge.canLiveSnapshot)
        XCTAssertTrue(bridge.canPartySnapshot)
    }

    func test_userType_102_blocksLive() {
        let (bridge, session) = makeBridge()
        sendSession(userType: 102, to: session); waitForSink()
        XCTAssertTrue(bridge.canCallSnapshot)
        XCTAssertFalse(bridge.canLiveSnapshot)
        XCTAssertTrue(bridge.canPartySnapshot)
    }

    func test_userType_103_blocksParty() {
        let (bridge, session) = makeBridge()
        sendSession(userType: 103, to: session); waitForSink()
        XCTAssertTrue(bridge.canCallSnapshot)
        XCTAssertTrue(bridge.canLiveSnapshot)
        XCTAssertFalse(bridge.canPartySnapshot)
    }

    func test_userType_104_blocksCallAndLive() {
        let (bridge, session) = makeBridge()
        sendSession(userType: 104, to: session); waitForSink()
        XCTAssertFalse(bridge.canCallSnapshot)
        XCTAssertFalse(bridge.canLiveSnapshot)
        XCTAssertTrue(bridge.canPartySnapshot)
    }

    func test_userType_105_blocksCallAndParty() {
        let (bridge, session) = makeBridge()
        sendSession(userType: 105, to: session); waitForSink()
        XCTAssertFalse(bridge.canCallSnapshot)
        XCTAssertTrue(bridge.canLiveSnapshot)
        XCTAssertFalse(bridge.canPartySnapshot)
    }

    func test_userType_106_blocksLiveAndParty() {
        let (bridge, session) = makeBridge()
        sendSession(userType: 106, to: session); waitForSink()
        XCTAssertTrue(bridge.canCallSnapshot)
        XCTAssertFalse(bridge.canLiveSnapshot)
        XCTAssertFalse(bridge.canPartySnapshot)
    }

    func test_userType_107_keepsPartyButBlocksSensitiveFeatures() {
        let (bridge, session) = makeBridge()
        sendSession(userType: 107, to: session); waitForSink()

        XCTAssertFalse(bridge.canCallSnapshot)
        XCTAssertFalse(bridge.canLiveSnapshot)
        XCTAssertTrue(bridge.canPartySnapshot)
        XCTAssertFalse(bridge.canGiftSendingSnapshot)
        XCTAssertFalse(bridge.canWalletSnapshot)
        XCTAssertFalse(bridge.canWithdrawalSnapshot)
        XCTAssertFalse(bridge.canCurrencyExchangeSnapshot)
        XCTAssertFalse(bridge.canLotterySnapshot)
        XCTAssertFalse(bridge.canPartyGamesSnapshot)
        XCTAssertFalse(bridge.canPartyLuckyNumberSnapshot)
        XCTAssertTrue(bridge.canPartyFreeGamesSnapshot)
        XCTAssertFalse(bridge.canVirtualItemsSnapshot)
        XCTAssertFalse(bridge.canHomeDiscoverySnapshot)
        XCTAssertFalse(bridge.canWorkDashboardSnapshot)
        XCTAssertFalse(bridge.canPartyActivitiesSnapshot)
        XCTAssertFalse(bridge.canDirectMessagesSnapshot)
        XCTAssertFalse(bridge.canProfileSocialSnapshot)
        XCTAssertFalse(bridge.canSystemAnnouncementsSnapshot)
        XCTAssertFalse(bridge.canPartyVideoSnapshot)
        XCTAssertTrue(bridge.canProfileViewingSnapshot)
    }

    func test_userTypes_101To106_keepNewSensitiveCapabilitiesEnabled() {
        for userType in 101...106 {
            let (bridge, session) = makeBridge()
            sendSession(userType: userType, to: session)

            XCTAssertTrue(bridge.canGiftSendingSnapshot, "userType \(userType) must retain gift permission")
            XCTAssertTrue(bridge.canWalletSnapshot, "userType \(userType) must retain wallet permission")
            XCTAssertTrue(bridge.canWithdrawalSnapshot, "userType \(userType) must retain withdrawal permission")
            XCTAssertTrue(bridge.canCurrencyExchangeSnapshot, "userType \(userType) must retain exchange permission")
            XCTAssertTrue(bridge.canLotterySnapshot, "userType \(userType) must retain lottery permission")
            XCTAssertTrue(bridge.canPartyGamesSnapshot, "userType \(userType) must retain game permission")
            XCTAssertTrue(bridge.canPartyLuckyNumberSnapshot, "userType \(userType) must retain Party Lucky Number permission")
            XCTAssertTrue(bridge.canPartyFreeGamesSnapshot, "userType \(userType) must retain free Party game permission")
            XCTAssertTrue(bridge.canVirtualItemsSnapshot, "userType \(userType) must retain virtual item permission")
            XCTAssertTrue(bridge.canHomeDiscoverySnapshot, "userType \(userType) must retain home permission")
            XCTAssertTrue(bridge.canWorkDashboardSnapshot, "userType \(userType) must retain work permission")
            XCTAssertTrue(bridge.canPartyActivitiesSnapshot, "userType \(userType) must retain activity permission")
            XCTAssertTrue(bridge.canDirectMessagesSnapshot, "userType \(userType) must retain P2P permission")
            XCTAssertTrue(bridge.canProfileSocialSnapshot, "userType \(userType) must retain social permission")
            XCTAssertTrue(bridge.canSystemAnnouncementsSnapshot, "userType \(userType) must retain announcement permission")
            XCTAssertTrue(bridge.canPartyVideoSnapshot, "userType \(userType) must retain Party video permission")
            XCTAssertTrue(bridge.canProfileViewingSnapshot, "userType \(userType) must retain profile viewing permission")
        }
    }

    func test_logoutAtomicallyRevokesPermissionsWithoutAnAllowState() async {
        let (bridge, session) = makeBridge()
        sendSession(userType: 107, to: session)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(bridge.canPartySnapshot)
        XCTAssertFalse(bridge.canCallSnapshot)

        session.send(.loggedOut)

        // Store snapshot is synchronous, so logout cannot expose the old two-relay
        // intermediate state: `blocked=[] + loaded=true`.
        for feature in PermissionFeature.allCases {
            XCTAssertFalse(bridge.canUseSnapshot(feature), "logout must immediately block \(String(describing: feature))")
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        await MainActor.run {
            XCTAssertFalse(bridge.isLoaded)
            XCTAssertFalse(bridge.canCall)
            XCTAssertFalse(bridge.canParty)
            XCTAssertFalse(bridge.canDirectMessages)
            XCTAssertFalse(bridge.canProfileViewing)
        }
    }

    func test_userType107_toNormalAccountRestoresCapabilities() {
        let (bridge, session) = makeBridge()
        sendSession(userType: 107, to: session)
        XCTAssertFalse(bridge.canDirectMessagesSnapshot)
        XCTAssertFalse(bridge.canGiftSendingSnapshot)

        sendSession(userType: 2, to: session)

        for feature in PermissionFeature.allCases {
            XCTAssertTrue(bridge.canUseSnapshot(feature), "normal account must restore \(String(describing: feature))")
        }
    }

    func test_userType_normalTo107_immediatelyRevokesPartyVideoButKeepsParty() {
        let (bridge, session) = makeBridge()
        sendSession(userType: 2, to: session)
        XCTAssertTrue(bridge.canPartySnapshot)
        XCTAssertTrue(bridge.canPartyVideoSnapshot)

        // Snapshot 在 publisher sink 内同步写入，RootView 可据此立即把已保留的 Party
        // RTC 会话收敛为纯语音，不能等待 SwiftUI 的下一帧 onChange。
        sendSession(userType: 107, to: session)

        XCTAssertTrue(bridge.canPartySnapshot)
        XCTAssertFalse(bridge.canPartyVideoSnapshot)
        XCTAssertFalse(bridge.canPartyLuckyNumberSnapshot)
        XCTAssertTrue(bridge.canPartyFreeGamesSnapshot)
        XCTAssertTrue(bridge.canProfileViewingSnapshot)
    }

    func test_partyFreeInteractionPolicy_allowsOnlyFreePartyInteractions() {
        XCTAssertTrue(PartyFreeInteractionPolicy.allows(
            gameID: "rps",
            gameName: nil,
            gameType: nil
        ))
        XCTAssertTrue(PartyFreeInteractionPolicy.allows(
            gameID: nil,
            gameName: "石头剪刀布",
            gameType: nil
        ))
        XCTAssertTrue(PartyFreeInteractionPolicy.allows(
            gameID: nil,
            gameName: "骰子",
            gameType: nil
        ))
        XCTAssertFalse(PartyFreeInteractionPolicy.allows(
            gameID: "super-wheel",
            gameName: "Super Wheel",
            gameType: "lottery"
        ))
    }

    // MARK: - Snapshot 与 @Published 双写最终一致

    func test_snapshotAndPublishedEventuallyConsistent() async {
        let (bridge, session) = makeBridge()
        sendSession(userType: 101, to: session)
        try? await Task.sleep(nanoseconds: 100_000_000)

        await MainActor.run {
            XCTAssertEqual(bridge.canCall, bridge.canCallSnapshot)
            XCTAssertEqual(bridge.canLive, bridge.canLiveSnapshot)
            XCTAssertEqual(bridge.canParty, bridge.canPartySnapshot)
            XCTAssertEqual(bridge.canGiftSending, bridge.canGiftSendingSnapshot)
            XCTAssertEqual(bridge.canWallet, bridge.canWalletSnapshot)
            XCTAssertEqual(bridge.canWithdrawal, bridge.canWithdrawalSnapshot)
            XCTAssertEqual(bridge.canCurrencyExchange, bridge.canCurrencyExchangeSnapshot)
            XCTAssertEqual(bridge.canLottery, bridge.canLotterySnapshot)
            XCTAssertEqual(bridge.canPartyGames, bridge.canPartyGamesSnapshot)
            XCTAssertEqual(bridge.canVirtualItems, bridge.canVirtualItemsSnapshot)
            XCTAssertEqual(bridge.canHomeDiscovery, bridge.canHomeDiscoverySnapshot)
            XCTAssertEqual(bridge.canWorkDashboard, bridge.canWorkDashboardSnapshot)
            XCTAssertEqual(bridge.canPartyActivities, bridge.canPartyActivitiesSnapshot)
            XCTAssertEqual(bridge.canDirectMessages, bridge.canDirectMessagesSnapshot)
            XCTAssertEqual(bridge.canProfileSocial, bridge.canProfileSocialSnapshot)
            XCTAssertEqual(bridge.canSystemAnnouncements, bridge.canSystemAnnouncementsSnapshot)
            XCTAssertEqual(bridge.canPartyVideo, bridge.canPartyVideoSnapshot)
            XCTAssertEqual(bridge.canPartyLuckyNumber, bridge.canPartyLuckyNumberSnapshot)
            XCTAssertEqual(bridge.canPartyFreeGames, bridge.canPartyFreeGamesSnapshot)
            XCTAssertEqual(bridge.canProfileViewing, bridge.canProfileViewingSnapshot)
        }
    }

    // MARK: - R-2: userType 变化立即传播（101 → 2 回归 all-true）

    func test_userType_change_recomputes() {
        let (bridge, session) = makeBridge()
        sendSession(userType: 101, to: session); waitForSink()
        XCTAssertFalse(bridge.canCallSnapshot)

        sendSession(userType: 2, to: session); waitForSink()
        XCTAssertTrue(bridge.canCallSnapshot, "userType 101 → 2 应恢复 canCall=true")
    }
}
