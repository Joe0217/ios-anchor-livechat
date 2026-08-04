import Foundation
import Combine

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
    /// 仅 107 使用：关闭关注关系、相册、动态和分享等非 Party 社交内容。
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
                .giftSending, .wallet, .withdrawal, .currencyExchange,
                .lottery, .partyGames, .virtualItems,
                .homeDiscovery, .workDashboard, .partyActivities,
                .directMessages, .profileSocial, .systemAnnouncements,
                .partyVideo, .partyLuckyNumber
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
    @MainActor @Published private(set) var canSystemAnnouncements: Bool = false
    @MainActor @Published private(set) var canPartyVideo: Bool = false
    @MainActor @Published private(set) var canPartyLuckyNumber: Bool = false
    @MainActor @Published private(set) var canPartyFreeGames: Bool = false
    @MainActor @Published private(set) var canProfileViewing: Bool = false
    @MainActor @Published private(set) var isLoaded: Bool = false

    // MARK: Store 层 nonisolated snapshot（原子读，避免 @MainActor hop）
    private let snapshotLock = NSLock()
    private var _snapshot: BlockedFeatures = []
    private var _snapshotLoaded: Bool = false

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
    nonisolated var canSystemAnnouncementsSnapshot: Bool { canUseSnapshot(.systemAnnouncements) }
    nonisolated var canPartyVideoSnapshot: Bool { canUseSnapshot(.partyVideo) }
    nonisolated var canPartyLuckyNumberSnapshot: Bool { canUseSnapshot(.partyLuckyNumber) }
    nonisolated var canPartyFreeGamesSnapshot: Bool { canUseSnapshot(.partyFreeGames) }
    nonisolated var canProfileViewingSnapshot: Bool { canUseSnapshot(.profileViewing) }

    /// 任意 actor 可读的能力快照。业务入口必须用它或 `gate`，不能只依赖 UI 显隐。
    nonisolated func canUseSnapshot(_ feature: PermissionFeature) -> Bool {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return _snapshotLoaded && !_snapshot.contains(feature.blockedFeature)
    }

    /// Store/View 层统一 gate helper（回应 code-review Finding 4/8）。
    ///
    /// 命中 = true 放行；不命中 = log warning + false。**不 assertionFailure** ——
    /// Bridge 双写 race window（微秒级 UI/Store 短暂不一致，见 §doc 承认）+ DebugPermissionOverride
    /// 热切换 + 后端 userType revoke 都会让"UI 上一帧 canCall=true 用户 tap → Store snapshot=false"
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
                self?.applyPermissions(
                    blocked: UserPermissionMapping.blocked(for: session.userType),
                    loaded: session.isAuthenticated
                )
            }
            .store(in: &cancellables)
    }

    /// sink 消费：Step 1 同步 snapshot lock；Step 2 派发 @MainActor 更新 @Published。
    /// UI task 不捕获本次入参，而是在执行时重读最新 snapshot，避免快速切换时较早 task
    /// 反向覆盖较新的登出/撤权结果。
    private func applyPermissions(blocked: BlockedFeatures, loaded: Bool) {
        // Step 1: 同步更新 snapshot lock 保护态（Store 层立即可见）
        snapshotLock.lock()
        _snapshot = blocked
        _snapshotLoaded = loaded
        snapshotLock.unlock()
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
        snapshotLock.unlock()

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
        canSystemAnnouncements = loaded && !blocked.contains(.systemAnnouncements)
        canPartyVideo = loaded && !blocked.contains(.partyVideo)
        canPartyLuckyNumber = loaded && !blocked.contains(.partyLuckyNumber)
        canPartyFreeGames = loaded && !blocked.contains(.partyFreeGames)
        canProfileViewing = loaded && !blocked.contains(.profileViewing)
        isLoaded = loaded
    }
}
