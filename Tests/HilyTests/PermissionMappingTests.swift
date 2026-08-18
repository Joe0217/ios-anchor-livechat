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

    func test_userTypeExperience_usesLoginMediaInsteadOfRawUserType() {
        let placeholderUser = makeLoginResult(
            userType: 2,
            videos: [ReviewAccountModePolicy.placeholderReviewVideoURL]
        )
        let regularUser = makeLoginResult(
            userType: 107,
            videos: ["https://cdn.example.com/real-review.mp4"]
        )

        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: placeholderUser), 107)
        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: regularUser), 2)
        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: nil), 107)
    }

    func test_userTypeExperience_missingMediaFieldsStays107UntilResolved() {
        let unknownUser = makeLoginResult(userType: 2, videos: nil)
        let knownEmptyUser = makeLoginResult(userType: 107, videos: [])

        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: unknownUser), 107)
        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: knownEmptyUser), 2)
    }

    func test_userTypeExperience_usesPersistedRawPlaceholderEvidence() {
        let user = LoginResult(
            userId: 7,
            token: "token",
            loginUuid: nil,
            yxAccid: nil,
            imToken: nil,
            userType: 2,
            nickname: nil,
            icon: nil,
            reviewPlaceholderVideoMatched: true
        )

        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: user), 107)
    }

    func test_userTypeExperience_missingUserIdentityFailsClosedTo107() {
        let missingIdentity = LoginResult(
            userId: nil,
            token: "token",
            loginUuid: nil,
            yxAccid: nil,
            imToken: nil,
            userType: 2,
            nickname: nil,
            icon: nil,
            videos: ["https://cdn.example.com/real-review.mp4"]
        )

        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: missingIdentity), 107)

        let invalidIdentity = LoginResult(
            userId: 0,
            token: "token",
            loginUuid: nil,
            yxAccid: nil,
            imToken: nil,
            userType: 2,
            nickname: nil,
            icon: nil,
            videos: []
        )
        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: invalidIdentity), 107)
    }

    func test_userTypeExperience_usesCurrentVersionResolvedFullMode() {
        let reviewUser = makeLoginResult(
            userType: 2,
            videos: [ReviewAccountModePolicy.placeholderReviewVideoURL]
        )
        let regularUser = makeLoginResult(userType: 2, videos: nil)
            .resolvingPermissionVideoURLs(["https://cdn.example.com/real-review.mp4"])

        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: reviewUser), 107)
        XCTAssertTrue(regularUser.isReviewModeResolved)
        XCTAssertEqual(
            regularUser.reviewModeEvidenceVersion,
            ReviewAccountModePolicy.currentEvidenceVersion
        )
        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: regularUser), 2)
    }

    func test_initialPermissionMode_usesVersionedCacheAndProfileEvidence() {
        let unresolved = makeLoginResult(userType: 2, videos: nil)

        let currentReviewMediaWins = makeLoginResult(
            userType: 2,
            videos: [ReviewAccountModePolicy.placeholderReviewVideoURL]
        ).resolvingInitialPermissionMode(
            cachedPermissionVideoURLs: ["https://cdn.example.com/stale-real.mp4"],
            cachedPlaceholderMatched: false
        )
        XCTAssertEqual(currentReviewMediaWins.source, "session-media")
        XCTAssertEqual(
            UserTypeExperience.effectiveUserType(userInfo: currentReviewMediaWins.user),
            107
        )

        let currentRealMediaWins = makeLoginResult(
            userType: 107,
            videos: ["https://cdn.example.com/current-real.mp4"]
        ).resolvingInitialPermissionMode(
            cachedPermissionVideoURLs: [ReviewAccountModePolicy.placeholderReviewVideoURL],
            cachedPlaceholderMatched: true
        )
        XCTAssertEqual(currentRealMediaWins.source, "session-media")
        XCTAssertEqual(
            UserTypeExperience.effectiveUserType(userInfo: currentRealMediaWins.user),
            2
        )

        let confirmedFullCache = unresolved.resolvingInitialPermissionMode(
            cachedPermissionVideoURLs: nil,
            cachedPlaceholderMatched: false
        )
        XCTAssertEqual(confirmedFullCache.source, "mode-cache-full")
        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: confirmedFullCache.user), 2)

        let confirmedReviewCache = unresolved.resolvingInitialPermissionMode(
            cachedPermissionVideoURLs: nil,
            cachedPlaceholderMatched: true
        )
        XCTAssertEqual(confirmedReviewCache.source, "mode-cache-review")
        XCTAssertEqual(
            UserTypeExperience.effectiveUserType(userInfo: confirmedReviewCache.user),
            107
        )
        XCTAssertEqual(
            confirmedReviewCache.user.reviewModeEvidenceVersion,
            ReviewAccountModePolicy.cachedModeEvidenceVersion
        )

        let cachedRealMedia = unresolved.resolvingInitialPermissionMode(
            cachedPermissionVideoURLs: ["https://cdn.example.com/real-review.mp4"],
            cachedPlaceholderMatched: nil
        )
        XCTAssertEqual(cachedRealMedia.source, "profile-cache-full")
        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: cachedRealMedia.user), 2)

        let restrictiveModeCacheWinsConflict = unresolved.resolvingInitialPermissionMode(
            cachedPermissionVideoURLs: [],
            cachedPlaceholderMatched: true
        )
        XCTAssertEqual(restrictiveModeCacheWinsConflict.source, "mode-cache-review")
        XCTAssertEqual(
            UserTypeExperience.effectiveUserType(userInfo: restrictiveModeCacheWinsConflict.user),
            107
        )

        let restrictiveProfileCacheWinsConflict = unresolved.resolvingInitialPermissionMode(
            cachedPermissionVideoURLs: [ReviewAccountModePolicy.placeholderReviewVideoURL],
            cachedPlaceholderMatched: false
        )
        XCTAssertEqual(restrictiveProfileCacheWinsConflict.source, "profile-cache-review")
        XCTAssertEqual(
            UserTypeExperience.effectiveUserType(userInfo: restrictiveProfileCacheWinsConflict.user),
            107
        )

        let noEvidence = unresolved.resolvingInitialPermissionMode(
            cachedPermissionVideoURLs: nil,
            cachedPlaceholderMatched: nil
        )
        XCTAssertEqual(noEvidence.source, "unresolved")
        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: noEvidence.user), 107)
    }

    func test_reloginFullAccountUsesItsOwnCachedModeAfterReviewAccount() {
        let reviewAccount = makeLoginResult(userID: 107_001, userType: 2, videos: nil)
            .resolvingInitialPermissionMode(
                cachedPermissionVideoURLs: nil,
                cachedPlaceholderMatched: true
            )
        let fullAccount = makeLoginResult(userID: 2_001, userType: 2, videos: nil)
            .resolvingInitialPermissionMode(
                cachedPermissionVideoURLs: nil,
                cachedPlaceholderMatched: false
            )

        XCTAssertNotEqual(reviewAccount.user.userId, fullAccount.user.userId)
        XCTAssertEqual(reviewAccount.source, "mode-cache-review")
        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: reviewAccount.user), 107)
        XCTAssertEqual(fullAccount.source, "mode-cache-full")
        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: fullAccount.user), 2)
    }

    func test_cachedModeEvidencePreservesBothModesAcrossRestore() {
        let cachedReview = makeLoginResult(userType: 2, videos: nil)
            .applyingCachedReviewPlaceholderMatch(true)
        let cachedFull = makeLoginResult(userType: 2, videos: nil)
            .applyingCachedReviewPlaceholderMatch(false)

        XCTAssertEqual(cachedReview.reviewModeEvidenceVersion, ReviewAccountModePolicy.cachedModeEvidenceVersion)
        XCTAssertEqual(cachedFull.reviewModeEvidenceVersion, ReviewAccountModePolicy.cachedModeEvidenceVersion)
        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: cachedReview), 107)
        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: cachedFull), 2)
    }

    func test_previousCachedModeEvidenceCannotOpenFullModeWithoutMedia() {
        let staleFullMode = LoginResult(
            userId: 7,
            token: "token",
            loginUuid: nil,
            yxAccid: nil,
            imToken: nil,
            userType: 2,
            nickname: nil,
            icon: nil,
            reviewPlaceholderVideoMatched: false,
            reviewModeResolved: true,
            reviewModeEvidenceVersion: 4
        )

        XCTAssertFalse(staleFullMode.isReviewModeResolved)
        XCTAssertNil(staleFullMode.resolvedReviewPlaceholderMatch)
        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: staleFullMode), 107)
    }

    func test_reviewModeRegistryMigratesOnlyRestrictiveLegacyEvidence() throws {
        let currentKey = KeychainKey.reviewModeByUserID
        let legacyKeys = KeychainKey.obsoleteReviewModeByUserID
        let originalCurrentData = KeychainStore.getData(for: currentKey)
        let originalLegacyData = Dictionary(uniqueKeysWithValues: legacyKeys.map {
            ($0, KeychainStore.getData(for: $0))
        })
        defer {
            if let originalCurrentData {
                _ = KeychainStore.setData(originalCurrentData, for: currentKey)
            } else {
                _ = KeychainStore.remove(for: currentKey)
            }
            for key in legacyKeys {
                if let originalData = originalLegacyData[key] ?? nil {
                    _ = KeychainStore.setData(originalData, for: key)
                } else {
                    _ = KeychainStore.remove(for: key)
                }
            }
        }

        _ = KeychainStore.remove(for: currentKey)
        for key in legacyKeys {
            _ = KeychainStore.remove(for: key)
        }
        let legacyKey = try XCTUnwrap(legacyKeys.last)
        let legacyValues = ["991107": true, "991002": false]
        XCTAssertTrue(KeychainStore.setData(
            try JSONEncoder().encode(legacyValues),
            for: legacyKey
        ))

        XCTAssertEqual(ReviewAccountModeRegistry.placeholderMatched(for: 991_107), true)
        XCTAssertNil(ReviewAccountModeRegistry.placeholderMatched(for: 991_002))
        XCTAssertNil(KeychainStore.getData(for: legacyKey))
    }

    func test_reviewModeRegistryRecoversFromCorruptedStorage() {
        let key = KeychainKey.reviewModeByUserID
        let originalData = KeychainStore.getData(for: key)
        defer {
            if let originalData {
                _ = KeychainStore.setData(originalData, for: key)
            } else {
                _ = KeychainStore.remove(for: key)
            }
        }

        XCTAssertTrue(KeychainStore.setData(Data("not-json".utf8), for: key))
        XCTAssertNil(ReviewAccountModeRegistry.placeholderMatched(for: 991_107))
        XCTAssertTrue(ReviewAccountModeRegistry.record(userID: 991_107, placeholderMatched: true))
        XCTAssertEqual(ReviewAccountModeRegistry.placeholderMatched(for: 991_107), true)
        XCTAssertTrue(ReviewAccountModeRegistry.record(userID: 991_107, placeholderMatched: false))
        XCTAssertEqual(ReviewAccountModeRegistry.placeholderMatched(for: 991_107), false)
    }

    func test_reviewAccountModePolicy_defaultsTo107WithoutCurrentUserInfo() {
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(
            isAuthenticated: true,
            hasUserInfo: false,
            videoURLs: []
        ), 107)
        XCTAssertNil(ReviewAccountModePolicy.effectiveUserType(
            isAuthenticated: false,
            hasUserInfo: false,
            videoURLs: []
        ))
    }

    func test_reviewAccountModePolicy_uses107OnlyForPlaceholderVideo() {
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(
            isAuthenticated: true,
            hasUserInfo: true,
            videoURLs: ["  \(ReviewAccountModePolicy.placeholderReviewVideoURL)  "]
        ), 107)
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(
            isAuthenticated: true,
            hasUserInfo: true,
            videoURLs: ["https://cdn.example.com/real-review.mp4"]
        ), 2)
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(
            isAuthenticated: true,
            hasUserInfo: true,
            videoURLs: []
        ), 2)
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(
            isAuthenticated: true,
            hasUserInfo: true,
            videoURLs: [],
            mediaInfoResolved: false
        ), 107)
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

    private func makeLoginResult(
        userID: Int = 7,
        userType: Int?,
        videos: [String]?
    ) -> LoginResult {
        LoginResult(
            userId: userID,
            token: "token",
            loginUuid: nil,
            yxAccid: nil,
            imToken: nil,
            userType: userType,
            nickname: nil,
            icon: nil,
            videos: videos
        )
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
        XCTAssertFalse(blocked.contains(.profileEditing))
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

        XCTAssertFalse(store.canEditRoomAvatar)

        await store.loadInitial()

        XCTAssertEqual(store.mode, PartyCreateStore.modeVoice)
        XCTAssertEqual(service.templateRequests, [PartyCreateStore.modeVoice])
        XCTAssertEqual(store.templates.map(\.id), [voice.id])
        XCTAssertTrue(store.visibleTemplates(for: PartyCreateStore.modeLiveVoice).isEmpty)
        XCTAssertEqual(store.selectedTemplate?.id, voice.id)
    }

    func test_partyOnlyCreateKeepsAccountAvatarAsDefault() async {
        let voice = PartyRoomTemplate(id: 1, modeType: PartyCreateStore.modeVoice, seatCount: 5)
        let service = PartyCreatePermissionService(templatesByType: [
            PartyCreateStore.modeVoice: [voice],
        ])
        let store = PartyCreateStore(
            service: service,
            defaultName: "Room",
            defaultTagline: "Welcome",
            defaultAvatarUrl: "https://example.com/hiFunny/20260817/register-107check/avatar.jpg",
            partyVideoCapabilityProvider: { false }
        )

        await store.loadInitial()
        await store.submit()

        XCTAssertEqual(service.createTemplateIDs, [voice.id])
        XCTAssertEqual(service.createAvatarURLs.count, 1)
        XCTAssertEqual(
            service.createAvatarURLs[0],
            "https://example.com/hiFunny/20260817/register-107check/avatar.jpg"
        )
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

        XCTAssertTrue(store.canEditRoomAvatar)

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
    private(set) var createAvatarURLs: [String?] = []

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
        createAvatarURLs.append(roomAvatar)
        let data = Data(#"{"id":"created-room","roomName":"Test"}"#.utf8)
        return try JSONDecoder().decode(PartyRoomInfo.self, from: data)
    }
}
