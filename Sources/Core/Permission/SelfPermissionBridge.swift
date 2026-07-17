import Foundation
import Combine

// MARK: - BlockedFeatures OptionSet

/// 权限受限功能的 3 bit 组合。`.call` bit 同时代表"通话 + 匹配"（用户业务规则）。
/// 判定语义：位命中 = 屏蔽该功能。
struct BlockedFeatures: OptionSet {
    let rawValue: Int
    static let call  = BlockedFeatures(rawValue: 1 << 0)
    static let live  = BlockedFeatures(rawValue: 1 << 1)
    static let party = BlockedFeatures(rawValue: 1 << 2)
}

// MARK: - UserPermissionMapping

/// `userType → BlockedFeatures` 映射。v1 硬编码；spec §8 明示 AppConfig 化需 v2 独立立项。
///
/// 已知语义：
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
        default:  return []
        }
    }
}

// MARK: - PermissionFeature

/// gate() 参数枚举。对应 BlockedFeatures 3 位（call bit 覆盖通话+匹配）。
enum PermissionFeature {
    case call
    case live
    case party
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
        let allowed: Bool
        switch feature {
        case .call:  allowed = canCallSnapshot
        case .live:  allowed = canLiveSnapshot
        case .party: allowed = canPartySnapshot
        }
        if !allowed {
            AppLogger.call.warning("[Permission] \(action, privacy: .public) blocked by userType gate (feature=\(String(describing: feature), privacy: .public))")
        }
        return allowed
    }

    private var cancellables = Set<AnyCancellable>()

    /// Publisher-inject 构造（无 SessionStore 编译依赖，白名单可测）。
    /// 生产装配见 `SelfPermissionBridge+Shared.swift`（挂 SessionStore.shared.$user.map { $0?.userType }）。
    ///
    /// **实现说明**（回应 Swift compiler type-check timeout）：Combine chain 拆 typed intermediate +
    /// sink closure 引用 method（避免 nested Task closure 类型推导指数爆炸）。
    init(
        userTypePublisher: AnyPublisher<Int?, Never>,
        loadedPublisher: AnyPublisher<Bool, Never>
    ) {
        // Step 1: userType → BlockedFeatures 派生（typed intermediate 让编译器逐步推导）
        let blockedPublisher: AnyPublisher<BlockedFeatures, Never> = userTypePublisher
            .removeDuplicates()
            .map { UserPermissionMapping.blocked(for: $0) }
            .eraseToAnyPublisher()

        // Step 2: 合并 blocked + loaded 双流
        let combined: AnyPublisher<(BlockedFeatures, Bool), Never> = blockedPublisher
            .combineLatest(loadedPublisher.removeDuplicates())
            .removeDuplicates(by: Self.tupleEqual)
            .eraseToAnyPublisher()

        // Step 3: sink 到 method 引用（避免 nested closure 类型推导超时）
        combined
            .sink { [weak self] tuple in
                self?.applyPermissions(blocked: tuple.0, loaded: tuple.1)
            }
            .store(in: &cancellables)
    }

    /// tuple 相等判定（提取为 static 方法给 removeDuplicates 用）
    private static func tupleEqual(_ a: (BlockedFeatures, Bool), _ b: (BlockedFeatures, Bool)) -> Bool {
        a.0 == b.0 && a.1 == b.1
    }

    /// sink 消费：Step 1 同步 snapshot lock；Step 2 派发 @MainActor 更新 @Published
    private func applyPermissions(blocked: BlockedFeatures, loaded: Bool) {
        // Step 1: 同步更新 snapshot lock 保护态（Store 层立即可见）
        snapshotLock.lock()
        _snapshot = blocked
        _snapshotLoaded = loaded
        snapshotLock.unlock()
        // Step 2: 异步派发到 MainActor 更新 @Published（UI 订阅响应）
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.canCall  = loaded && !blocked.contains(.call)
            self.canLive  = loaded && !blocked.contains(.live)
            self.canParty = loaded && !blocked.contains(.party)
            self.isLoaded = loaded
        }
    }
}
