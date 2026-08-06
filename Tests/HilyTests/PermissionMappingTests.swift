import Foundation
import XCTest
// test 文件不写 @testable import Hily —— HilyTests 是独立 module（白名单约定）

/// 覆盖 spec §5 F-1 ~ F-10 + R-3 + BlockedFeatures 位运算属性。
/// 见 [P-plan-用户权限管理系统-*.md] Task 2。
final class PermissionMappingTests: XCTestCase {

    // MARK: - F-1 ~ F-3: 未受限 userType

    func test_userType_2_isFullyAllowed() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: 2), [])
    }

    func test_userType_9_isFullyAllowed() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: 9), [])
    }

    func test_userType_nil_isFullyAllowed() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: nil), [])
    }

    func test_userTypeExperience_routesPermissionAccountsToMainApp() {
        XCTAssertTrue(UserTypeExperience.canEnterMainApp(2))
        for userType in 101...107 {
            XCTAssertTrue(UserTypeExperience.canEnterMainApp(userType))
        }
        XCTAssertFalse(UserTypeExperience.canEnterMainApp(nil))
        XCTAssertFalse(UserTypeExperience.canEnterMainApp(1))
        XCTAssertFalse(UserTypeExperience.canEnterMainApp(3))
        XCTAssertFalse(UserTypeExperience.canEnterMainApp(9))
    }

    func test_userTypeExperience_isFixedTo107ForEveryAuthenticatedSession() {
        XCTAssertEqual(UserTypeExperience.fixedUserType, 107)
        XCTAssertEqual(UserTypeExperience.effectiveUserType(isAuthenticated: true), 107)
        XCTAssertNil(UserTypeExperience.effectiveUserType(isAuthenticated: false))
    }

    func test_userTypeExperience_separatesPartyOnlyFromFullHostRealtime() {
        XCTAssertTrue(UserTypeExperience.hasFullHostRealtimeCapability(2))
        for userType in 101...106 {
            XCTAssertTrue(UserTypeExperience.hasFullHostRealtimeCapability(userType))
        }
        XCTAssertFalse(UserTypeExperience.hasFullHostRealtimeCapability(107))
        XCTAssertTrue(UserTypeExperience.isPartyOnly(107))
        XCTAssertFalse(UserTypeExperience.isPartyOnly(2))
        XCTAssertFalse(UserTypeExperience.isPartyOnly(nil))
    }

    // MARK: - F-4 ~ F-9: 六种黑名单 userType 矩阵

    func test_userType_101_blocksCallOnly() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: 101), [.call])
    }

    func test_userType_102_blocksLiveOnly() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: 102), [.live])
    }

    func test_userType_103_blocksPartyOnly() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: 103), [.party])
    }

    func test_userType_104_blocksCallAndLive() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: 104), [.call, .live])
    }

    func test_userType_105_blocksCallAndParty() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: 105), [.call, .party])
    }

    func test_userType_106_blocksLiveAndParty() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: 106), [.live, .party])
    }

    func test_userTypes_101Through106_keep107OnlyFeaturesAllowed() {
        let featuresReservedFor107: BlockedFeatures = [
            .giftSending, .wallet, .withdrawal, .currencyExchange,
            .lottery, .partyGames, .virtualItems,
            .homeDiscovery, .workDashboard, .partyActivities,
            .directMessages, .profileSocial, .systemAnnouncements,
            .partyVideo, .partyLuckyNumber, .partyMusic
        ]

        for userType in 101...106 {
            let blocked = UserPermissionMapping.blocked(for: userType)
            XCTAssertEqual(
                blocked.intersection(featuresReservedFor107),
                [],
                "userType \(userType) must not inherit 107-only restrictions"
            )
        }
    }

    func test_userType_107_isPartyOnlyProfile() {
        let blocked = UserPermissionMapping.blocked(for: 107)
        XCTAssertFalse(blocked.contains(.party))
        XCTAssertTrue(blocked.contains(.call))
        XCTAssertTrue(blocked.contains(.live))
        XCTAssertTrue(blocked.contains(.giftSending))
        XCTAssertTrue(blocked.contains(.wallet))
        XCTAssertTrue(blocked.contains(.withdrawal))
        XCTAssertTrue(blocked.contains(.currencyExchange))
        XCTAssertTrue(blocked.contains(.lottery))
        XCTAssertTrue(blocked.contains(.partyGames))
        XCTAssertTrue(blocked.contains(.virtualItems))
        XCTAssertTrue(blocked.contains(.homeDiscovery))
        XCTAssertTrue(blocked.contains(.workDashboard))
        XCTAssertTrue(blocked.contains(.partyActivities))
        XCTAssertTrue(blocked.contains(.directMessages))
        XCTAssertTrue(blocked.contains(.profileSocial))
        XCTAssertTrue(blocked.contains(.systemAnnouncements))
        XCTAssertTrue(blocked.contains(.partyVideo))
        XCTAssertTrue(blocked.contains(.partyLuckyNumber))
        XCTAssertTrue(blocked.contains(.partyMusic))
        XCTAssertFalse(blocked.contains(.partyFreeGames))
        XCTAssertFalse(blocked.contains(.profileViewing))
        XCTAssertFalse(blocked.contains(.relationshipViewing))
        XCTAssertFalse(blocked.contains(.relationshipActions))
        XCTAssertFalse(blocked.contains(.supportMessaging))
        XCTAssertFalse(blocked.contains(.beautyStudio))
        XCTAssertFalse(blocked.contains(.profileAlbum))
    }

    // MARK: - R-3: 未知 userType 视为不受限

    func test_userType_unknownValues_defaultToEmpty() {
        XCTAssertEqual(UserPermissionMapping.blocked(for: 200), [])
        XCTAssertEqual(UserPermissionMapping.blocked(for: 50), [])
        XCTAssertEqual(UserPermissionMapping.blocked(for: 0), [])
        XCTAssertEqual(UserPermissionMapping.blocked(for: 999), [])
        XCTAssertEqual(UserPermissionMapping.blocked(for: -1), [])
    }

    // MARK: - BlockedFeatures 位运算基础属性

    func test_blockedFeatures_containsSingleBit() {
        XCTAssertTrue(BlockedFeatures.call.contains(.call))
        XCTAssertFalse(BlockedFeatures.call.contains(.live))
        XCTAssertFalse(BlockedFeatures.call.contains(.party))
    }

    func test_blockedFeatures_combinationContainsIndividualBits() {
        let combo: BlockedFeatures = [.call, .live]
        XCTAssertTrue(combo.contains(.call))
        XCTAssertTrue(combo.contains(.live))
        XCTAssertFalse(combo.contains(.party))
    }
}

@MainActor
final class PartyCreateStorePermissionTests: XCTestCase {

    func test_partyOnlyLoadInitialRequestsOnlyVoiceTemplates() async {
        let voice = PartyRoomTemplate(id: 1, modeType: PartyCreateStore.modeVoice, seatCount: 5)
        let live = PartyRoomTemplate(id: 2, modeType: PartyCreateStore.modeLiveVoice, videoSeatCount: 1)
        let service = PartyCreatePermissionService(templatesByType: [
            PartyCreateStore.modeVoice: [voice],
            PartyCreateStore.modeLiveVoice: [live],
        ])
        let store = PartyCreateStore(service: service, partyVideoCapabilityProvider: { false })

        await store.loadInitial()

        XCTAssertEqual(store.mode, PartyCreateStore.modeVoice)
        XCTAssertEqual(service.templateRequests, [PartyCreateStore.modeVoice])
        XCTAssertEqual(store.templates.map(\.id), [voice.id])
        XCTAssertTrue(store.visibleTemplates(for: PartyCreateStore.modeLiveVoice).isEmpty)
        XCTAssertEqual(store.selectedTemplate?.id, voice.id)
    }

    func test_partyOnlyRejectsStaleVideoTemplateBeforeSubmission() async {
        let voice = PartyRoomTemplate(id: 1, modeType: PartyCreateStore.modeVoice, seatCount: 5)
        let live = PartyRoomTemplate(id: 2, modeType: PartyCreateStore.modeLiveVoice, videoSeatCount: 1)
        let service = PartyCreatePermissionService(templatesByType: [
            PartyCreateStore.modeVoice: [voice],
            PartyCreateStore.modeLiveVoice: [live],
        ])
        var canUsePartyVideo = true
        let store = PartyCreateStore(
            service: service,
            defaultName: "Room",
            defaultTagline: "Welcome",
            partyVideoCapabilityProvider: { canUsePartyVideo }
        )

        await store.loadInitial()
        XCTAssertTrue(store.selectMode(PartyCreateStore.modeLiveVoice))
        XCTAssertTrue(store.selectTemplate(live, for: PartyCreateStore.modeLiveVoice))

        canUsePartyVideo = false
        await store.submit()

        XCTAssertFalse(store.selectMode(PartyCreateStore.modeLiveVoice))
        XCTAssertFalse(store.selectTemplate(live, for: PartyCreateStore.modeLiveVoice))
        XCTAssertTrue(service.createTemplateIDs.isEmpty)
        XCTAssertEqual(store.mode, PartyCreateStore.modeVoice)
        XCTAssertTrue(store.visibleTemplates(for: PartyCreateStore.modeLiveVoice).isEmpty)
    }

    func test_normalAccountKeepsLiveAndVoiceTemplatesAvailable() async {
        let voice = PartyRoomTemplate(id: 1, modeType: PartyCreateStore.modeVoice, seatCount: 5)
        let live = PartyRoomTemplate(id: 2, modeType: PartyCreateStore.modeLiveVoice, videoSeatCount: 1)
        let service = PartyCreatePermissionService(templatesByType: [
            PartyCreateStore.modeVoice: [voice],
            PartyCreateStore.modeLiveVoice: [live],
        ])
        let store = PartyCreateStore(service: service, partyVideoCapabilityProvider: { true })

        await store.loadInitial()

        XCTAssertEqual(store.mode, PartyCreateStore.modeLiveVoice)
        XCTAssertEqual(Set(service.templateRequests), [PartyCreateStore.modeVoice, PartyCreateStore.modeLiveVoice])
        XCTAssertEqual(store.visibleTemplates(for: PartyCreateStore.modeLiveVoice).map(\.id), [live.id])
        XCTAssertTrue(store.selectMode(PartyCreateStore.modeLiveVoice))
    }
}

private final class PartyCreatePermissionService: PartyCreateService, @unchecked Sendable {
    let templatesByType: [Int: [PartyRoomTemplate]]
    private(set) var templateRequests: [Int] = []
    private(set) var createTemplateIDs: [Int] = []

    init(templatesByType: [Int: [PartyRoomTemplate]]) {
        self.templatesByType = templatesByType
    }

    func fetchTemplates(type: Int) async throws -> [PartyRoomTemplate] {
        templateRequests.append(type)
        return templatesByType[type] ?? []
    }

    func fetchLanguages() async throws -> [PartyLanguage] {
        [PartyLanguage(languageName: "English", languageCode: "en")]
    }

    func fetchBackgrounds() async throws -> [PartyBackground] { [] }

    func fetchCreateConditions() async throws -> PartyCreateConditions {
        PartyCreateConditions(canCreateRoom: true, createRoomLevel: nil, isWithlist: nil)
    }

    func createRoom(
        roomName: String,
        greetingMessage: String,
        roomLanguage: String,
        roomTempId: Int,
        roomAvatar: String?,
        bgImgId: Int?
    ) async throws -> PartyRoomInfo {
        createTemplateIDs.append(roomTempId)
        let data = Data(#"{"id":"created-room","roomName":"Test"}"#.utf8)
        return try JSONDecoder().decode(PartyRoomInfo.self, from: data)
    }
}
