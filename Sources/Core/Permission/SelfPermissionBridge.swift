import Foundation
import Combine

/// 注册审核图片的稳定路径标记。判断基于 URL 内容而非媒体数组索引，兼容接口重排及百分号编码。
enum RegistrationReviewMediaPolicy {
    static let pathMarker = "register-107check"

    static func containsMarker(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        if value.range(of: pathMarker, options: [.caseInsensitive]) != nil { return true }
        return value.removingPercentEncoding?
            .range(of: pathMarker, options: [.caseInsensitive]) != nil
    }

    static func containsMarker(_ url: URL?) -> Bool {
        containsMarker(url?.absoluteString)
    }

    static func shouldMask(_ url: URL?, effectiveUserType: Int?) -> Bool {
        UserTypeExperience.isPartyOnly(effectiveUserType) && containsMarker(url)
    }
}

/// 审核账号的本地 UGC 前置过滤。服务端内容审核仍是最终防线；这里负责在发送/提交前
/// 即时阻断明显的色情、仇恨、暴力、毒品、骚扰和自残内容，并兼容常见字符规避。
enum ObjectionableContentFilter {
    private static let tokenTerms: Set<String> = [
        // English
        "sex", "sexual", "porn", "porno", "pornography", "nude", "nudes", "nudity",
        "rape", "rapist", "raping", "pedophile", "pedophilia", "incest", "bestiality",
        "sexting", "grooming", "molester", "molestation", "prostitute", "prostitution",
        "blowjob", "handjob", "gangbang", "nazi", "terrorist", "terrorism", "genocide",
        "cocaine", "heroin", "methamphetamine", "meth", "fentanyl", "ketamine", "ecstasy",
        "doxxing", "beheading", "decapitation", "massacre", "murder", "suicide",
        "fuck", "motherfucker", "asshole", "bullshit", "shit", "bitch", "whore", "slut",
        "nigger", "kike", "chink", "faggot",
        // Turkish (diacritics are folded during normalization)
        "porno", "pornografi", "ciplak", "tecavuz", "pedofili", "uyusturucu",
        "kokain", "eroin", "terorist", "orospu", "intihar",
        // Arabic
        "اباحي", "اباحية", "عاري", "اغتصاب", "مخدرات", "كوكايين", "هيروين",
        "ارهابي", "نازي", "انتحار",
    ]

    private static let phraseTerms: [String] = [
        "child porn", "child pornography", "child sexual", "child abuse", "underage sex",
        "underage nude", "sexual services", "send nudes", "rape you", "kill yourself",
        "go kill yourself", "commit suicide", "suicide pact", "i will kill you",
        "im going to kill you", "death threat", "bomb threat", "shoot up", "buy drugs",
        "sell drugs", "white power", "heil hitler", "fuck you", "fuck off",
        "piece of shit", "son of a bitch",
        "cocuk pornosu", "kendini oldur", "uyusturucu sat",
        "اقتل نفسك", "مواد اباحية", "بيع مخدرات",
    ]

    /// 去掉分隔符后仍匹配的高置信短语，用于拦截 `p.o.r.n`、`k1ll yourself` 等规避。
    /// 只放低误伤词，不对普通短词做任意子串匹配。
    private static let compactTerms: [String] = [
        "porn", "pornography", "pedophile", "pedophilia", "bestiality", "blowjob",
        "handjob", "gangbang", "fuck", "motherfucker", "asshole", "bullshit", "bitch",
        "whore", "slut", "nigger", "kike", "faggot", "childporn",
        "childpornography", "childsexual", "childabuse", "underagesex", "underagenude",
        "killyourself", "gokillyourself", "commitsuicide", "suicidepact", "iwillkillyou",
        "imgoingtokillyou", "deaththreat", "sexualservices", "sendnudes", "rapeyou",
        "buydrugs", "selldrugs", "bombthreat", "shootup", "heilhitler", "whitepower",
        "fuckyou", "fuckoff", "pieceofshit", "sonofabitch",
        "cocukpornosu", "kendinioldur", "uyusturucusat",
    ]

    private static let directSubstringTerms: [String] = [
        "色情", "儿童色情", "裸聊", "强奸", "迷奸", "乱伦", "约炮", "援交",
        "毒品", "冰毒", "海洛因", "可卡因", "恐怖袭击", "纳粹", "自杀", "杀了你", "去死",
    ]

    static func containsObjectionableContent(_ input: String) -> Bool {
        let normalized = collapseExcessiveRepeats(in: normalize(input))
        guard !normalized.isEmpty else { return false }

        let tokens = Set(normalized.split(separator: " ").map(String.init))
        if !tokens.isDisjoint(with: tokenTerms) { return true }
        if phraseTerms.contains(where: { normalized.contains($0) }) { return true }

        let compact = normalized.replacingOccurrences(of: " ", with: "")
        if compactTerms.contains(where: { compact.contains($0) }) { return true }
        return directSubstringTerms.contains(where: { compact.contains($0) })
    }

    static func shouldBlock(_ input: String, effectiveUserType: Int?) -> Bool {
        UserTypeExperience.isPartyOnly(effectiveUserType)
            && containsObjectionableContent(input)
    }

    /// 107 展示服务端 UGC 前的最后一道防线。非 107 原样返回，避免影响正式模式。
    static func sanitizedForDisplay(
        _ input: String,
        replacement: String,
        effectiveUserType: Int?
    ) -> String {
        shouldBlock(input, effectiveUserType: effectiveUserType) ? replacement : input
    }

    private static func normalize(_ input: String) -> String {
        let folded = input.precomposedStringWithCompatibilityMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var result = ""
        var previousWasSeparator = true

        for scalar in folded.unicodeScalars {
            let replacement: Character?
            switch scalar.value {
            case 48: replacement = "o"       // 0
            case 49: replacement = "i"       // 1
            case 51: replacement = "e"       // 3
            case 52: replacement = "a"       // 4
            case 53: replacement = "s"       // 5
            case 55: replacement = "t"       // 7
            case 64: replacement = "a"       // @
            case 36: replacement = "s"       // $
            default: replacement = nil
            }

            if let replacement {
                result.append(replacement)
                previousWasSeparator = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append(" ")
                previousWasSeparator = true
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// 将 3 个及以上连续相同字符压缩为 1 个，兼容 `fuuuck` 一类规避；正常双写单词不受影响。
    private static func collapseExcessiveRepeats(in input: String) -> String {
        var result = ""
        var previous: Character?
        var runLength = 0

        for character in input {
            if character == previous {
                runLength += 1
            } else {
                if let previous {
                    result += String(repeating: String(previous), count: runLength >= 3 ? 1 : runLength)
                }
                previous = character
                runLength = 1
            }
        }
        if let previous {
            result += String(repeating: String(previous), count: runLength >= 3 ? 1 : runLength)
        }
        return result
    }
}

// MARK: - BlockedFeatures OptionSet

/// 权限受限功能的 bit 组合。`.call` 同时代表"通话 + 匹配"。
///
/// 101-106 保持既有三项能力矩阵；107 是 Party-only 角色，额外关闭
/// 经济和随机玩法，但不会影响其他账号类型。
/// 判定语义：位命中 = 屏蔽该功能。
struct BlockedFeatures: OptionSet {
    let rawValue: Int
    static let call  = BlockedFeatures(rawValue: 1 << 0)
    static let live  = BlockedFeatures(rawValue: 1 << 1)
    static let party = BlockedFeatures(rawValue: 1 << 2)
    static let giftSending = BlockedFeatures(rawValue: 1 << 3)
    static let wallet = BlockedFeatures(rawValue: 1 << 4)
    static let withdrawal = BlockedFeatures(rawValue: 1 << 5)
    static let currencyExchange = BlockedFeatures(rawValue: 1 << 6)
    static let lottery = BlockedFeatures(rawValue: 1 << 7)
    static let partyGames = BlockedFeatures(rawValue: 1 << 8)
    static let virtualItems = BlockedFeatures(rawValue: 1 << 9)
    /// 仅 107 使用：Party-only 角色不展示首页直播/匹配/发现内容。
    static let homeDiscovery = BlockedFeatures(rawValue: 1 << 10)
    /// 仅 107 使用：Party-only 角色不展示工作台中的收益、任务和运营入口。
    static let workDashboard = BlockedFeatures(rawValue: 1 << 11)
    /// 仅 107 使用：Party-only 角色不打开服务端下发的 Party H5 活动页。
    static let partyActivities = BlockedFeatures(rawValue: 1 << 12)
    /// 仅 107 使用：关闭 P2P 消息、群发和私密媒体链路；Party 房公屏不受此位影响。
    static let directMessages = BlockedFeatures(rawValue: 1 << 13)
    /// 朋友圈发布由本地图片/文字预检保护；107 仍关闭其他高风险社交媒体编辑能力。
    /// 关注关系与只读 Album 已拆成更窄的独立能力，不再复用此位。
    static let profileSocial = BlockedFeatures(rawValue: 1 << 14)
    /// 仅 107 使用：不展示非 Party 的启动站内公告。
    static let systemAnnouncements = BlockedFeatures(rawValue: 1 << 15)
    /// 仅 107 使用：Party 房保留语音和公屏互动，但不采集或展示视频麦位。
    static let partyVideo = BlockedFeatures(rawValue: 1 << 16)
    /// Party 房 Lucky Number；与外部抽奖/转盘分离，107 仍单独屏蔽。
    static let partyLuckyNumber = BlockedFeatures(rawValue: 1 << 17)
    /// 仅限服务端标识为免费互动的 Party 游戏（猜拳、骰子）；PK 和其他游戏不在此范围内。
    static let partyFreeGames = BlockedFeatures(rawValue: 1 << 18)
    /// 他人基础资料的只读查看及举报/拉黑安全处置；与关注、私聊等社交动作分离。
    static let profileViewing = BlockedFeatures(rawValue: 1 << 19)
    /// Following / Followers / Friends 数字和列表的只读查看。
    static let relationshipViewing = BlockedFeatures(rawValue: 1 << 20)
    /// 关注和取关写操作；不包含私信、朋友圈、分享等社交能力。
    static let relationshipActions = BlockedFeatures(rawValue: 1 << 21)
    /// 仅允许与服务端返回的客服 IM 账号建立 P2P 会话。
    static let supportMessaging = BlockedFeatures(rawValue: 1 << 22)
    /// 本地美颜设置、相机预览和拍照保存；不包含直播、通话或 Party 视频。
    static let beautyStudio = BlockedFeatures(rawValue: 1 << 23)
    /// 本人资料页 Album 的只读展示；媒体编辑仍由 profileSocial 管理。
    static let profileAlbum = BlockedFeatures(rawValue: 1 << 24)
    /// Party 房音乐列表、管理入口和本地收听。
    static let partyMusic = BlockedFeatures(rawValue: 1 << 25)
    /// 本人基础资料、头像和照片编辑；视频、朋友圈及问候语仍由 profileSocial 管理。
    static let profileEditing = BlockedFeatures(rawValue: 1 << 26)
}

/// 认证态与 userType 必须作为同一条事件传给权限桥。
///
/// `userType == nil` 对已登录账号仍是合法的未知类型，不能被误判成登出；因此不能再由两个
/// 独立 publisher 在下游 `combineLatest`。登出时使用 `.loggedOut` 一次性收回全部能力。
struct PermissionSessionState: Equatable {
    let userType: Int?
    let isAuthenticated: Bool

    static let loggedOut = PermissionSessionState(userType: nil, isAuthenticated: false)
}

/// 用户对象、userId 或当前媒体证据缺失时保持 107。认证建立时可使用同一 userId 的
/// 版本化模式缓存补足缺失媒体；本次登录响应中的明确媒体始终优先于缓存。
enum ReviewAccountModePolicy {
    static let placeholderReviewVideoURL = "https://img.hnhily.link/00000000/20260806/8c2bc4a182a8483e92c38c06518d1d87.mp4"
    /// v1 曾把“登录响应无媒体”持久化为已确认的全功能。升级版本后旧 false 证据失效，
    /// 防止覆盖安装继续沿用错误权限。
    static let currentEvidenceVersion = 2
    /// v5 双向模式缓存来源标记。登录响应缺媒体时可直接恢复 107 或全开放首帧，
    /// 资料刷新只更新下次认证所用缓存，不再热切当前会话。
    static let cachedModeEvidenceVersion = 5

    static func effectiveUserType(
        isAuthenticated: Bool,
        hasUserInfo: Bool,
        videoURLs: [String],
        rawPlaceholderMatched: Bool? = nil,
        mediaInfoResolved: Bool = true
    ) -> Int? {
        guard isAuthenticated else { return nil }
        guard hasUserInfo else { return 107 }
        guard mediaInfoResolved else { return 107 }
        let hasPlaceholderVideo = rawPlaceholderMatched == true || videoURLs.contains { url in
            url.trimmingCharacters(in: .whitespacesAndNewlines) == placeholderReviewVideoURL
        }
        return hasPlaceholderVideo ? 107 : 2
    }

    static func isPlaceholderVideoURL(_ rawURL: String) -> Bool {
        rawURL.trimmingCharacters(in: .whitespacesAndNewlines) == placeholderReviewVideoURL
    }

    static func effectiveUserType(userInfo: LoginResult?) -> Int? {
        // App 启动、登出完成以及 Keychain 无可恢复用户时都保持审核模式。认证状态由
        // PermissionSessionState.isAuthenticated 单独控制，因此这里返回 107 不会在登录前放行能力。
        guard let userInfo else { return 107 }
        return effectiveUserType(
            isAuthenticated: true,
            hasUserInfo: userInfo.userId.map { $0 > 0 } == true,
            videoURLs: userInfo.permissionModeMediaURLs,
            rawPlaceholderMatched: userInfo.resolvedReviewPlaceholderMatch,
            mediaInfoResolved: userInfo.isReviewModeResolved
        )
    }
}

/// 权限桥输出的有效模式对应哪种主界面运行形态。
enum UserTypeExperience {
    /// UI 与服务层首帧都直接读取当前会话快照，不能等待权限 Bridge 的异步发布。
    static func effectiveUserType(userInfo: LoginResult?) -> Int? {
        ReviewAccountModePolicy.effectiveUserType(userInfo: userInfo)
    }

    static func canEnterMainApp(_ userType: Int?) -> Bool {
        guard let userType else { return false }
        return userType == 2 || (101...107).contains(userType)
    }

    static func hasFullHostRealtimeCapability(_ userType: Int?) -> Bool {
        guard let userType else { return false }
        return userType == 2 || (101...106).contains(userType)
    }

    static func isPartyOnly(_ userType: Int?) -> Bool {
        userType == 107
    }
}

// MARK: - UserPermissionMapping

/// `userType → BlockedFeatures` 映射。v1 硬编码；spec §8 明示 AppConfig 化需 v2 独立立项。
///
/// 已知语义：
/// - 107：Party-only 角色；保留 Party 基础互动，关闭高风险扩展
/// - 未知/未受限 userType（2/9/nil/其他）→ 返回 `[]`
/// - 101-106 → 六种黑名单组合（spec §2.2 矩阵）
enum UserPermissionMapping {
    static func blocked(for userType: Int?) -> BlockedFeatures {
        switch userType {
        case 101: return [.call]
        case 102: return [.live]
        case 103: return [.party]
        case 104: return [.call, .live]
        case 105: return [.call, .party]
        case 106: return [.live, .party]
        case 107:
            return [
                .call, .live,
                .profileSocial,
                .giftSending, .wallet, .withdrawal, .currencyExchange,
                .lottery, .partyGames, .virtualItems,
                .homeDiscovery, .workDashboard, .partyActivities,
                .directMessages, .systemAnnouncements,
                .partyVideo, .partyLuckyNumber, .partyMusic
            ]
        default:  return []
        }
    }
}

// MARK: - PermissionFeature

/// gate() 参数枚举。每项对应一个 `BlockedFeatures` bit。
enum PermissionFeature: CaseIterable {
    case call
    case live
    case party
    case giftSending
    case wallet
    case withdrawal
    case currencyExchange
    case lottery
    case partyGames
    case virtualItems
    case homeDiscovery
    case workDashboard
    case partyActivities
    case directMessages
    case profileSocial
    case systemAnnouncements
    case partyVideo
    case partyLuckyNumber
    case partyFreeGames
    case profileViewing
    case relationshipViewing
    case relationshipActions
    case supportMessaging
    case beautyStudio
    case profileAlbum
    case partyMusic
    case profileEditing

    fileprivate var blockedFeature: BlockedFeatures {
        switch self {
        case .call: return .call
        case .live: return .live
        case .party: return .party
        case .giftSending: return .giftSending
        case .wallet: return .wallet
        case .withdrawal: return .withdrawal
        case .currencyExchange: return .currencyExchange
        case .lottery: return .lottery
        case .partyGames: return .partyGames
        case .virtualItems: return .virtualItems
        case .homeDiscovery: return .homeDiscovery
        case .workDashboard: return .workDashboard
        case .partyActivities: return .partyActivities
        case .directMessages: return .directMessages
        case .profileSocial: return .profileSocial
        case .systemAnnouncements: return .systemAnnouncements
        case .partyVideo: return .partyVideo
        case .partyLuckyNumber: return .partyLuckyNumber
        case .partyFreeGames: return .partyFreeGames
        case .profileViewing: return .profileViewing
        case .relationshipViewing: return .relationshipViewing
        case .relationshipActions: return .relationshipActions
        case .supportMessaging: return .supportMessaging
        case .beautyStudio: return .beautyStudio
        case .profileAlbum: return .profileAlbum
        case .partyMusic: return .partyMusic
        case .profileEditing: return .profileEditing
        }
    }
}

// MARK: - SelfPermissionBridge

/// 权限判定 Bridge（对齐 spec §2.3 双 API）：
/// - UI @MainActor 上下文用 `$canX @Published`（Combine 声明式响应）
/// - Store async 非 @MainActor method 用 `canXSnapshot` nonisolated 原子读（避免跨 actor hop）
///
/// **不变量**：同一 sink 内先写 snapshot lock（同步）再 dispatch @MainActor Task 更新 @Published；
/// 微秒级 window 内 UI 与 Store 可能不一致，UI 下一 frame 自愈。属安全属性合理代价（deny-by-default fail-safe）。
///
/// **单例约束**：全项目一律用 `SelfPermissionBridge.shared`（见 `SelfPermissionBridge+Shared.swift`），
/// 禁止 `@StateObject SelfPermissionBridge()` new 独立实例（见 rule prefer-shared-component-over-adhoc）。
final class SelfPermissionBridge: ObservableObject, @unchecked Sendable {

    // MARK: UI 层订阅（@MainActor + @Published）
    /// 根据当前用户资料派生的有效账号模式（107 或 2）。
    @MainActor @Published private(set) var effectiveUserType: Int? = nil
    @MainActor @Published private(set) var canCall: Bool = false
    @MainActor @Published private(set) var canLive: Bool = false
    @MainActor @Published private(set) var canParty: Bool = false
    @MainActor @Published private(set) var canGiftSending: Bool = false
    @MainActor @Published private(set) var canWallet: Bool = false
    @MainActor @Published private(set) var canWithdrawal: Bool = false
    @MainActor @Published private(set) var canCurrencyExchange: Bool = false
    @MainActor @Published private(set) var canLottery: Bool = false
    @MainActor @Published private(set) var canPartyGames: Bool = false
    @MainActor @Published private(set) var canVirtualItems: Bool = false
    @MainActor @Published private(set) var canHomeDiscovery: Bool = false
    @MainActor @Published private(set) var canWorkDashboard: Bool = false
    @MainActor @Published private(set) var canPartyActivities: Bool = false
    @MainActor @Published private(set) var canDirectMessages: Bool = false
    @MainActor @Published private(set) var canProfileSocial: Bool = false
    @MainActor @Published private(set) var canCircleSocial: Bool = false
    @MainActor @Published private(set) var canSystemAnnouncements: Bool = false
    @MainActor @Published private(set) var canPartyVideo: Bool = false
    @MainActor @Published private(set) var canPartyLuckyNumber: Bool = false
    @MainActor @Published private(set) var canPartyFreeGames: Bool = false
    @MainActor @Published private(set) var canProfileViewing: Bool = false
    @MainActor @Published private(set) var canRelationshipViewing: Bool = false
    @MainActor @Published private(set) var canRelationshipActions: Bool = false
    @MainActor @Published private(set) var canSupportMessaging: Bool = false
    @MainActor @Published private(set) var canBeautyStudio: Bool = false
    @MainActor @Published private(set) var canProfileAlbum: Bool = false
    @MainActor @Published private(set) var canPartyMusic: Bool = false
    @MainActor @Published private(set) var canProfileEditing: Bool = false
    @MainActor @Published private(set) var isLoaded: Bool = false

    // MARK: Store 层 nonisolated snapshot（原子读，避免 @MainActor hop）
    private let snapshotLock = NSLock()
    private var _snapshot: BlockedFeatures = []
    private var _snapshotLoaded: Bool = false
    private var _effectiveUserTypeSnapshot: Int?

    /// Store/连接层读取的有效账号类型；登出或权限桥未加载时恒为 nil。
    nonisolated var effectiveUserTypeSnapshot: Int? {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return _snapshotLoaded ? _effectiveUserTypeSnapshot : nil
    }

    /// **Store guard 专用**：nonisolated 原子快照读；从任意 actor 调都安全。
    /// UI 层继续读 `$canCall @MainActor @Published`（Bridge 内部同步双写）。
    nonisolated var canCallSnapshot: Bool {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return _snapshotLoaded && !_snapshot.contains(.call)
    }
    nonisolated var canLiveSnapshot: Bool {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return _snapshotLoaded && !_snapshot.contains(.live)
    }
    nonisolated var canPartySnapshot: Bool {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return _snapshotLoaded && !_snapshot.contains(.party)
    }
    nonisolated var canGiftSendingSnapshot: Bool { canUseSnapshot(.giftSending) }
    nonisolated var canWalletSnapshot: Bool { canUseSnapshot(.wallet) }
    nonisolated var canWithdrawalSnapshot: Bool { canUseSnapshot(.withdrawal) }
    nonisolated var canCurrencyExchangeSnapshot: Bool { canUseSnapshot(.currencyExchange) }
    nonisolated var canLotterySnapshot: Bool { canUseSnapshot(.lottery) }
    nonisolated var canPartyGamesSnapshot: Bool { canUseSnapshot(.partyGames) }
    nonisolated var canVirtualItemsSnapshot: Bool { canUseSnapshot(.virtualItems) }
    nonisolated var canHomeDiscoverySnapshot: Bool { canUseSnapshot(.homeDiscovery) }
    nonisolated var canWorkDashboardSnapshot: Bool { canUseSnapshot(.workDashboard) }
    nonisolated var canPartyActivitiesSnapshot: Bool { canUseSnapshot(.partyActivities) }
    nonisolated var canDirectMessagesSnapshot: Bool { canUseSnapshot(.directMessages) }
    nonisolated var canProfileSocialSnapshot: Bool { canUseSnapshot(.profileSocial) }
    nonisolated var canCircleSocialSnapshot: Bool { canUseSnapshot(.profileSocial) || effectiveUserTypeSnapshot == 107 }
    nonisolated var canSystemAnnouncementsSnapshot: Bool { canUseSnapshot(.systemAnnouncements) }
    nonisolated var canPartyVideoSnapshot: Bool { canUseSnapshot(.partyVideo) }
    nonisolated var canPartyLuckyNumberSnapshot: Bool { canUseSnapshot(.partyLuckyNumber) }
    nonisolated var canPartyFreeGamesSnapshot: Bool { canUseSnapshot(.partyFreeGames) }
    nonisolated var canProfileViewingSnapshot: Bool { canUseSnapshot(.profileViewing) }
    nonisolated var canRelationshipViewingSnapshot: Bool { canUseSnapshot(.relationshipViewing) }
    nonisolated var canRelationshipActionsSnapshot: Bool { canUseSnapshot(.relationshipActions) }
    nonisolated var canSupportMessagingSnapshot: Bool { canUseSnapshot(.supportMessaging) }
    nonisolated var canBeautyStudioSnapshot: Bool { canUseSnapshot(.beautyStudio) }
    nonisolated var canProfileAlbumSnapshot: Bool { canUseSnapshot(.profileAlbum) }
    nonisolated var canPartyMusicSnapshot: Bool { canUseSnapshot(.partyMusic) }
    nonisolated var canProfileEditingSnapshot: Bool { canUseSnapshot(.profileEditing) }

    /// 任意 actor 可读的能力快照。业务入口必须用它或 `gate`，不能只依赖 UI 显隐。
    nonisolated func canUseSnapshot(_ feature: PermissionFeature) -> Bool {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return _snapshotLoaded && !_snapshot.contains(feature.blockedFeature)
    }

    /// Store/View 层统一 gate helper（回应 code-review Finding 4/8）。
    ///
    /// 命中 = true 放行；不命中 = log warning + false。**不 assertionFailure** ——
    /// Bridge 双写 race window（微秒级 UI/Store 短暂不一致，见 §doc 承认）+ 资料模式热切换
    /// 都会让"UI 上一帧 canCall=true 用户 tap → Store snapshot=false"
    /// 成为**合法并发**，不是 invariant 违反。原 v1 各 Store 层 `#if DEBUG assertionFailure` 会
    /// 崩 Debug build（v1 spec §3.2 遗留问题）。改用 log warning + return false，caller 早退。
    ///
    /// 消除 5 处 8 行复制 guard 块（CallStore.callOut / handleIncomingVideoCall /
    /// MatchStore.openMatch / LiveSettingsStore.startTapped / PartyStore.enterRoom）。
    nonisolated func gate(_ feature: PermissionFeature, action: String) -> Bool {
        let allowed = canUseSnapshot(feature)
        if !allowed {
            AppLogger.call.warning("[Permission] \(action, privacy: .public) blocked by userType gate (feature=\(String(describing: feature), privacy: .public))")
        }
        return allowed
    }

    private var cancellables = Set<AnyCancellable>()

    /// Publisher-inject 构造（无 SessionStore 编译依赖，白名单可测）。
    ///
    /// 认证态与 userType 必须由上游原子地一起发出。生产装配见
    /// `SelfPermissionBridge+Shared.swift`，它直接把 `SessionStore.$user` 映射为
    /// `PermissionSessionState`，避免 logout 时先得到“nil userType + 已登录”的全放行组合。
    ///
    /// 上游先完成会话快照组装，本类只做权限映射和双层状态发布。
    init(sessionPublisher: AnyPublisher<PermissionSessionState, Never>) {
        sessionPublisher
            .removeDuplicates()
            .sink { [weak self] session in
                self?.synchronize(session)
            }
            .store(in: &cancellables)
    }

    /// SessionStore 在建立/结束认证会话时同步调用，确保 SwiftUI 重建新账号页面前，Store 快照
    /// 已经切到同一账号。生产 publisher 仍保留，负责冷启动绑定和后续状态观察。
    nonisolated func synchronize(_ session: PermissionSessionState) {
        applyPermissions(
            userType: session.userType,
            blocked: UserPermissionMapping.blocked(for: session.userType),
            loaded: session.isAuthenticated
        )
    }

    /// 登录/登出都发生在 MainActor。这里在发布新页面代际前同步更新 Store 快照和 SwiftUI
    /// `@Published` 权限，避免热切账号时新页面首帧读到上一账号的能力。
    @MainActor
    func synchronizeImmediately(_ session: PermissionSessionState) {
        applyPermissions(
            userType: session.userType,
            blocked: UserPermissionMapping.blocked(for: session.userType),
            loaded: session.isAuthenticated,
            schedulesMainActorPublish: false
        )
        publishCurrentSnapshot()
    }

    /// sink 消费：Step 1 同步 snapshot lock；Step 2 派发 @MainActor 更新 @Published。
    /// UI task 不捕获本次入参，而是在执行时重读最新 snapshot，避免快速切换时较早 task
    /// 反向覆盖较新的登出/撤权结果。
    private func applyPermissions(
        userType: Int?,
        blocked: BlockedFeatures,
        loaded: Bool,
        schedulesMainActorPublish: Bool = true
    ) {
        // Step 1: 同步更新 snapshot lock 保护态（Store 层立即可见）
        snapshotLock.lock()
        _snapshot = blocked
        _snapshotLoaded = loaded
        _effectiveUserTypeSnapshot = loaded ? userType : nil
        snapshotLock.unlock()

        #if DEBUG
        AppLogger.auth.info(
            "[PermissionBridgeSnapshot] authenticated=\(loaded, privacy: .public) effectiveUserType=\(loaded ? (userType ?? -1) : -1, privacy: .public) blockedMask=\(blocked.rawValue, privacy: .public) call=\(loaded && !blocked.contains(.call), privacy: .public) party=\(loaded && !blocked.contains(.party), privacy: .public) home=\(loaded && !blocked.contains(.homeDiscovery), privacy: .public) messages=\(loaded && !blocked.contains(.directMessages), privacy: .public) partyVideo=\(loaded && !blocked.contains(.partyVideo), privacy: .public)"
        )
        #endif

        guard schedulesMainActorPublish else { return }
        // Step 2: 异步派发到 MainActor 更新 @Published（UI 订阅响应）
        Task { @MainActor [weak self] in
            self?.publishCurrentSnapshot()
        }
    }

    @MainActor
    private func publishCurrentSnapshot() {
        snapshotLock.lock()
        let blocked = _snapshot
        let loaded = _snapshotLoaded
        let userType = _effectiveUserTypeSnapshot
        snapshotLock.unlock()

        effectiveUserType = loaded ? userType : nil
        canCall  = loaded && !blocked.contains(.call)
        canLive  = loaded && !blocked.contains(.live)
        canParty = loaded && !blocked.contains(.party)
        canGiftSending = loaded && !blocked.contains(.giftSending)
        canWallet = loaded && !blocked.contains(.wallet)
        canWithdrawal = loaded && !blocked.contains(.withdrawal)
        canCurrencyExchange = loaded && !blocked.contains(.currencyExchange)
        canLottery = loaded && !blocked.contains(.lottery)
        canPartyGames = loaded && !blocked.contains(.partyGames)
        canVirtualItems = loaded && !blocked.contains(.virtualItems)
        canHomeDiscovery = loaded && !blocked.contains(.homeDiscovery)
        canWorkDashboard = loaded && !blocked.contains(.workDashboard)
        canPartyActivities = loaded && !blocked.contains(.partyActivities)
        canDirectMessages = loaded && !blocked.contains(.directMessages)
        canProfileSocial = loaded && !blocked.contains(.profileSocial)
        canCircleSocial = canProfileSocial || (loaded && userType == 107)
        canSystemAnnouncements = loaded && !blocked.contains(.systemAnnouncements)
        canPartyVideo = loaded && !blocked.contains(.partyVideo)
        canPartyLuckyNumber = loaded && !blocked.contains(.partyLuckyNumber)
        canPartyFreeGames = loaded && !blocked.contains(.partyFreeGames)
        canProfileViewing = loaded && !blocked.contains(.profileViewing)
        canRelationshipViewing = loaded && !blocked.contains(.relationshipViewing)
        canRelationshipActions = loaded && !blocked.contains(.relationshipActions)
        canSupportMessaging = loaded && !blocked.contains(.supportMessaging)
        canBeautyStudio = loaded && !blocked.contains(.beautyStudio)
        canProfileAlbum = loaded && !blocked.contains(.profileAlbum)
        canPartyMusic = loaded && !blocked.contains(.partyMusic)
        canProfileEditing = loaded && !blocked.contains(.profileEditing)
        isLoaded = loaded

        #if DEBUG
        AppLogger.auth.info(
            "[PermissionBridgePublished] loaded=\(self.isLoaded, privacy: .public) effectiveUserType=\(self.effectiveUserType ?? -1, privacy: .public) call=\(self.canCall, privacy: .public) party=\(self.canParty, privacy: .public) home=\(self.canHomeDiscovery, privacy: .public) messages=\(self.canDirectMessages, privacy: .public) partyVideo=\(self.canPartyVideo, privacy: .public)"
        )
        #endif
    }
}
