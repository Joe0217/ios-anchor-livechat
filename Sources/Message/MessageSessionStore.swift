import Combine
import Foundation
import UIKit
import os

/// P2P 会话列表 Store（H-1 MVP，spec §2.2；v4 扩展 Flame 顶部 3 系统消息入口）。
///
/// **职责**：
/// - 会话列表拉取（首次 + retry）
/// - Prime 拉取（分批 ≤50 uid）
/// - **系统消息 3 入口派生**（Station HTTP / Notification P2P / Admin P2P；v4 新增）
/// - NIM delegate 增量更新合并（loading 期间入队 pendingUpdates，loaded 后按合并语义应用）
/// - 置顶 / 删除乐观更新 + 失败回滚
/// - 分类过滤派生（view 层观察 `sessions(in:)`）；**排除** notification/admin session
///
/// **无 SDK 依赖**：所有数据源走 protocol —— Adapter / Prime / Station / CustomerService。
@MainActor
final class MessageSessionStore: ObservableObject {

    // MARK: - 对外状态

    @Published private(set) var state: MessageSessionState = .idle
    @Published var selectedCategory: MessageSessionCategory = .flame

    /// Flame 顶部 3 系统消息入口（Station / Notification / Admin，v4 新增）
    @Published private(set) var systemInboxEntries: [SystemInboxEntry] = []

    /// Station 最新一条 mail（v4 新增，Flame 顶部 station 入口数据源）
    @Published private(set) var stationMail: StationMail?

    /// 当前分类下的 sessions（view 层订阅）
    var currentSessions: [MessageSession] {
        sessions(in: selectedCategory)
    }

    /// 派生：按分类过滤（H-2 v2 对齐 H5 filter 独立语义 —— Prime 与 Flame 可重叠）；
    /// **排除 notification/admin session**（v4）。
    /// 排序规则：`isTop desc` 先，`lastMessageTimestamp desc` 次
    func sessions(in category: MessageSessionCategory) -> [MessageSession] {
        guard case .loaded(let all) = state else { return [] }
        let excludedIds = excludedSystemIds()
        return all
            .filter { !excludedIds.contains($0.id) }
            .filter { session in
                let activeTycoon = conversationProfiles[session.id]?.activeTycoon ?? false
                switch category {
                case .flame:
                    return MessageSessionClassifier.isFlame(session,
                                                            flameUserIdSet: flameUserIdSet,
                                                            profileActiveTycoon: activeTycoon)
                case .prime:
                    return MessageSessionClassifier.isPrime(session, primeUidSet: primeUidSet)
                case .stranger:
                    return MessageSessionClassifier.isStranger(session,
                                                               flameUserIdSet: flameUserIdSet,
                                                               profileActiveTycoon: activeTycoon)
                }
            }
            .sorted { lhs, rhs in
                if lhs.isTop != rhs.isTop { return lhs.isTop }
                return lhs.lastMessageTimestamp > rhs.lastMessageTimestamp
            }
    }

    /// 按 peerYxAccId 查找现有 session（H-2 spec §4.2：chat store 发送成功后主动 emit .update 需先取现有 session 做字段合并）。
    /// 未加载或找不到返回 nil。
    func session(byPeerId peerId: String) -> MessageSession? {
        guard case .loaded(let all) = state else { return nil }
        return all.first { $0.id == peerId }
    }

    /// 每分类未读数聚合（H5 index.vue calculateUnreadCount 对齐）。tab 标题旁 badge 显示用。
    /// Flame 页含系统消息未读（Station/Notification/Admin），v4 起在 Flame 加总；Prime/Stranger 仅常规 P2P。
    func unreadCount(in category: MessageSessionCategory) -> Int {
        var base = sessions(in: category).reduce(0) { $0 + $1.unreadCount }
        if category == .flame {
            base += systemInboxEntries.reduce(0) { $0 + $1.unread }
        }
        return base
    }

    // MARK: - 依赖

    private let provider: MessageSessionProviderProtocol
    private let primeProvider: PrimeLevelProviderProtocol
    private let stationProvider: StationListProviderProtocol
    private let customerServiceStore: CustomerServiceIdProviderProtocol
    private let profileProvider: ConversationProfileProviderProtocol
    private let followProvider: FollowUserListProviderProtocol

    /// 对端 yxAccId → profile 的缓存（v4: 批量拉 apiBatchQueryYxStat 后覆盖 sessions 的 nickname/avatar）。
    /// 增量事件 add 时也追加拉取。
    private(set) var conversationProfiles: [String: ConversationProfile] = [:]

    /// v4e：view 层查等级/VIP/活跃大 R 用（row 视觉增强）。
    func profile(for sessionId: String) -> ConversationProfile? {
        conversationProfiles[sessionId]
    }

    // MARK: - 内部态

    /// loading 期间入队；loaded 后合并
    private var pendingUpdates: [MessageSessionEvent] = []
    /// Prime uid 集合（拉取结果；失败降级为空集，Flame/Stranger 不受影响 —— R-1）
    private(set) var primeUidSet: Set<String> = []
    /// Flame 通道 B：关注列表 yxAccid 集合（H-2 v2 对齐 H5 `sessionFlameUserIdList`）。
    /// 拉取失败保留旧值（H5 同款降级）。
    private(set) var flameUserIdSet: Set<String> = []

    /// **internal**（非 private）以便 `MessageSessionStore+IdleCleanup.swift` extension 挂 sink
    /// （extension 位于同 module 不同文件，`private` 会阻断访问）
    var cancellables = Set<AnyCancellable>()

    /// v4e: 20s 周期在线状态刷新任务（对齐 H5 `timingUpdateUserState`；普通场景 10-30s 频率）。
    /// load() 完成时启动；deinit / 显式 clear / 切后台时取消。
    private var onlineStatusRefreshTask: Task<Void, Never>?
    private static let onlineStatusRefreshIntervalSec: UInt64 = 20

    /// v5 F-1: 后台观察者句柄（切后台 pause task；回前台 restart 单次 refresh）
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    /// v5.5 空闲清理机制常量（bubbly-leaping-comet plan）
    private static let cleanupStaleThresholdMs: Int64 = 30 * 24 * 3600 * 1000       // 30 天
    private static let cleanupCountLimit: Int = 200                                  // 会话数上限
    private static let cleanupCountLimitMinAgeMs: Int64 = 15 * 24 * 3600 * 1000     // 规则 B 附加：最旧 <15 天不清

    /// v5.5 清理任务重入 guard：AutoOffline sink 短时间多次触发也只执行一次
    private var isCleaningUp: Bool = false

    /// IM sessions/漫游消息是否已 sync（真轨映射 `NIMService.$isSessionSyncOK`）。
    /// 冷启动 auto-login sync 阶段 fetchAll 返空是"未就绪假空"——load() 判 empty 分支时用它
    /// 决定是否保留 .loading 等 publisher sink 触发 reload，避免直接切 .loaded([]) 让用户见空态。
    private var isIMSynced: Bool = false

    /// 107 撤销 P2P 后，Store 仍会被 NIM 的 connection publisher 唤醒。仅隐藏消息 Tab
    /// 无法阻止它重拉会话、用户资料和关注列表，因此此处保留独立的运行时暂停态。
    private var isDirectMessagesSuspended: Bool = false
    /// 每次暂停/恢复递增。异步请求返回时必须与启动时的 epoch 一致，避免撤权前已经发出的
    /// 请求把旧会话或资料重新写回内存。
    private var directMessagesAccessEpoch: UInt = 0

    private let logger = Logger(subsystem: "com.anchor.livechat", category: "MessageSessionStore")

    // MARK: - init / teardown

    init(provider: MessageSessionProviderProtocol,
         primeProvider: PrimeLevelProviderProtocol,
         stationProvider: StationListProviderProtocol = StationListService.shared,
         customerServiceStore: CustomerServiceIdProviderProtocol = CustomerServiceIdStore.shared,
         profileProvider: ConversationProfileProviderProtocol = ConversationProfileService.shared,
         followProvider: FollowUserListProviderProtocol = FollowUserListService.shared) {
        self.provider = provider
        self.primeProvider = primeProvider
        self.stationProvider = stationProvider
        self.customerServiceStore = customerServiceStore
        self.profileProvider = profileProvider
        self.followProvider = followProvider

        // 订阅 delegate 增量事件（Adapter 保证 @MainActor 回调）
        provider.subscribe { [weak self] event in
            self?.handleEvent(event)
        }

        // Step 3 反悔 #1 修复（状态机错）：订阅 IM 长连接态，`isConnected` 后（含首次登录 + 重连）
        // 自动触发 load——避免 tab 冷启动早于 IM login 时 `allRecentSessions()` 返空 → 用户看到永久空态。
        //
        // v4f 反悔 #5 修复（切账号/重连 stale cache）：**syncOK 到达无条件 reload**，不 skip loaded 非空态。
        // 原因：Store 是 `.shared` 单例，切账号 / 重连后 state 仍是旧账号 .loaded(旧 sessions) → skip 导致
        // 20s 轮询也走旧 sessions.id → 用户看到旧数据 + 陈旧 online 状态，重启 App 才 fresh。H5 也是每次进
        // 消息页 reload（不缓存跨会话）；对齐此语义。
        provider.isConnectedPublisher
            .removeDuplicates()
            .sink { [weak self] isConnected in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // 无条件更新本地 sync 标记（load() 空返守卫用；断连时置回 false）
                    self.isIMSynced = isConnected
                    guard isConnected else { return }
                    guard !self.isDirectMessagesSuspended else {
                        self.logger.debug("🟣 [MessageStore] isConnected=true ignored while P2P is suspended")
                        return
                    }
                    self.logger.info("🟢 [MessageStore] isConnected=true → reload (无条件覆盖 stale cache)")
                    await self.load()
                }
            }
            .store(in: &cancellables)

        // v4 新增：客服 yxAccId 变化后重算 3 入口（登录后 refreshIfNeeded → publisher fire）
        customerServiceStore.customerYxAccIdPublisher
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, !self.isDirectMessagesSuspended else { return }
                self.recomputeSystemInbox()
            }
            .store(in: &cancellables)

        // v5.5 空闲清理机制的 AutoOfflineMonitor sink 挂载见 `MessageSessionStore+IdleCleanup.swift`
        // （AutoOfflineMonitor 依赖 SwiftUI/UIKit，不入 HilyTests target；extension 拆分模式对齐
        // BlocklistViewModel+Runtime.swift 已有实践）
    }

    // MARK: - 加载

    /// M-8:state 短摘要(不含 associated value 里的会话字段),用于 log .public 输出避免 PII 泄漏
    /// e.g. `loaded(count:42)` / `idle` / `loading` / `error`
    private static func stateKindLabel(_ state: MessageSessionState) -> String {
        switch state {
        case .idle: return "idle"
        case .loading: return "loading"
        case .loaded(let sessions): return "loaded(count:\(sessions.count))"
        case .error: return "error"
        }
    }

    func load() async {
        guard !isDirectMessagesSuspended else {
            logger.debug("🟣 [MessageStore] load ignored while P2P is suspended")
            return
        }
        let accessEpoch = directMessagesAccessEpoch
        // M-8:state=.loaded([MessageSession]) reflection dump 会带 peerNickname/lastMessage/yxAccid 等 PII,
        // 用短摘要替代整 state,避免 unified log 泄漏聊天摘要(App Store 5.1.1 privacy 相关)
        logger.info("🟢 [MessageStore] load() start stateKind=\(Self.stateKindLabel(self.state), privacy: .public)")
        // v5.1 修复（Q2）：已 loaded 非空态下的 reload（下拉刷新 / 重连 syncOK）**不切 loading**，
        // 保留旧数据让 SwiftUI .refreshable 自带的下拉转圈指示器承载 loading 视觉，
        // 避免消息列表闪烁（消失→ProgressView→重现）。
        // 仅冷启动（.idle）或错误恢复（.error）切 loading 显示 ProgressView。
        let hasLoadedData: Bool = {
            if case .loaded(let s) = self.state, !s.isEmpty { return true }
            return false
        }()
        if !hasLoadedData {
            state = .loading
        }

        // v4 新增：客服 yxAccId 幂等拉取（若已缓存立即返；否则并发拉取不阻塞主路径）
        Task { [weak self] in
            guard let self, self.isDirectMessagesAccessActive(accessEpoch) else { return }
            await self.customerServiceStore.refreshIfNeeded()
        }

        // v4 新增：station HTTP 拉取（不阻塞主路径 sessions/prime）
        Task { [weak self] in
            guard let self, self.isDirectMessagesAccessActive(accessEpoch) else { return }
            let mail = await self.stationProvider.fetchLatest()
            await MainActor.run { [weak self] in
                guard let self, self.isDirectMessagesAccessActive(accessEpoch) else { return }
                self.stationMail = mail
                self.recomputeSystemInbox()
            }
        }

        do {
            let all = try await provider.fetchAll()
            guard isDirectMessagesAccessActive(accessEpoch) else { return }
            logger.info("🟢 [MessageStore] fetchAll returned count=\(all.count, privacy: .public)")

            // v5.2 修复（Q3 IM 断连保护）：fetchAll 拿到空数组时，若当前 state 已 loaded 非空
            // → 视为"IM 未就绪的假空"（allRecentSessions() 在 SDK 未登录时会返空），保留旧数据
            // 不覆盖。真空账号从 .idle/.error 走覆盖路径；断连恢复由下次 syncOK sink 触发 load
            // 拉到真数据覆盖。避免下拉刷新在断连时清空整个消息列表。
            //
            // v5.6 补冷启动路径：IM 未 syncOK 时 fetchAll 返空是"未就绪假空"（现有 loaded 保护
            // 覆盖不到冷启的 .loading 状态）。保持 .loading 让 UI 显 ProgressView，等 publisher
            // sink 触发下一轮 load 拉到真数据；避免用户看空态误以为"没消息"要下拉刷新才有。
            if all.isEmpty {
                if case .loaded(let current) = state, !current.isEmpty {
                    logger.notice("🟠 [MessageStore] fetchAll returned empty but cache has \(current.count, privacy: .public) sessions — preserving (likely IM disconnected)")
                    return
                }
                if !isIMSynced {
                    logger.notice("🟠 [MessageStore] fetchAll returned empty + IM not synced — keep loading, wait for sync")
                    // state 保持 .loading（进入本函数时已切）；publisher sink 会在 syncOK 触发下一轮 load
                    return
                }
            }

            // Prime + Profile + FollowList 并发拉取（排除 notification/admin session id）
            let excludedIds = excludedSystemIds()
            let uidsForBatch = all.map(\.id).filter { !excludedIds.contains($0) }
            async let primesTask = primeProvider.fetchPrime(yxAccIds: uidsForBatch)
            async let profilesTask = profileProvider.fetch(yxAccIds: uidsForBatch)
            // H-2 v2 · Flame 通道 B：拉关注列表（对齐 H5 `updateFlameUserList` + `useFollowUserList`）
            // 首次拉 → 打网；后续 24h 内命中缓存；失败保留旧值（H5 同款）
            async let followTask = followProvider.fetch()
            let newPrimes = await primesTask
            let newProfiles = await profilesTask
            let newFollowSet = await followTask
            guard isDirectMessagesAccessActive(accessEpoch) else { return }

            // v5.3 修复（Q4 Prime 分类丢失）：primeUidSet 拉到空且原本非空 → 保留旧值。
            // 原因：PrimeLevelService.fetchPrime 全批失败降级为空 Set（spec R-1）；直接覆盖赋值会
            // 让下拉刷新时 Prime 拉失败瞬间清空 primeUidSet → 之前分类 Prime 的会话全部
            // 落 Stranger（Stranger 是分类兜底）。同 Q3 fetchAll 假空保护思路。
            // conversationProfiles 用 formUnion 语义天然不清空（for-in 只覆盖有值 key），无需额外保护。
            if !newPrimes.isEmpty || primeUidSet.isEmpty {
                primeUidSet = newPrimes
            } else {
                logger.notice("🟠 [MessageStore] prime fetched empty but cache has \(self.primeUidSet.count, privacy: .public) — preserving")
            }
            // 关注列表同款保护：拉到空且原本非空 → 保留旧值（H5 `useFollowUserList.js:53-57` 失败保留缓存）
            if !newFollowSet.isEmpty || flameUserIdSet.isEmpty {
                flameUserIdSet = newFollowSet
            } else {
                logger.notice("🟠 [MessageStore] followList fetched empty but cache has \(self.flameUserIdSet.count, privacy: .public) — preserving")
            }
            for (k, v) in newProfiles { conversationProfiles[k] = v }
            logger.info("🟢 [MessageStore] prime=\(self.primeUidSet.count, privacy: .public) profiles=\(newProfiles.count, privacy: .public) followList=\(self.flameUserIdSet.count, privacy: .public)")

            // 应用 loading 期间累积的 delegate 事件（R-3）
            let merged = pendingUpdates.mergedByLastTerminal()
            pendingUpdates.removeAll()

            let applied = applyEvents(merged, to: all)
            let finalSessions = applyProfiles(to: applied)   // v4d: nickname/avatar 覆盖
            // v7 · 分类分布诊断（对齐安卓 3 通道 Flame）
            let excluded = excludedSystemIds()
            let visible = finalSessions.filter { !excluded.contains($0.id) }
            let profs = conversationProfiles
            let flameCount = visible.filter {
                MessageSessionClassifier.isFlame($0,
                                                 flameUserIdSet: flameUserIdSet,
                                                 profileActiveTycoon: profs[$0.id]?.activeTycoon ?? false)
            }.count
            let primeCount = visible.filter { MessageSessionClassifier.isPrime($0, primeUidSet: primeUidSet) }.count
            let strangerCount = visible.filter {
                MessageSessionClassifier.isStranger($0,
                                                    flameUserIdSet: flameUserIdSet,
                                                    profileActiveTycoon: profs[$0.id]?.activeTycoon ?? false)
            }.count
            let overlapFlamePrime = visible.filter {
                MessageSessionClassifier.isFlame($0,
                                                 flameUserIdSet: flameUserIdSet,
                                                 profileActiveTycoon: profs[$0.id]?.activeTycoon ?? false)
                    && MessageSessionClassifier.isPrime($0, primeUidSet: primeUidSet)
            }.count
            logger.info("🟢 [MessageStore] classify total=\(visible.count, privacy: .public) flame=\(flameCount, privacy: .public) prime=\(primeCount, privacy: .public) stranger=\(strangerCount, privacy: .public) flame∩prime=\(overlapFlamePrime, privacy: .public)")
            state = .loaded(finalSessions)
            recomputeSystemInbox()
            startOnlineStatusRefresh()   // v4e: 启动 20s 周期在线状态刷新
            logger.info("🟢 [MessageStore] loaded final count=\(finalSessions.count, privacy: .public) pendingMerged=\(merged.count, privacy: .public)")
        } catch {
            guard isDirectMessagesAccessActive(accessEpoch) else { return }
            state = .error(String(describing: error))
            logger.error("🔴 [MessageStore] load failed \(String(describing: error), privacy: .private)")
        }
    }

    func retry() async {
        await load()
    }

    // MARK: - Delegate 增量事件（Adapter → @MainActor）

    func handleEvent(_ event: MessageSessionEvent) {
        guard !isDirectMessagesSuspended else { return }
        switch state {
        case .loading:
            pendingUpdates.append(event)
        case .loaded(let current):
            let updated = applyEvents([event], to: current)
            state = .loaded(applyProfiles(to: updated))
            recomputeSystemInbox()   // v4: session 增量变化后重算 3 入口（notification/admin 的 unread/preview）
            // 增量新 session：追加 uid 到 Prime + profile pending queue（排除 notification/admin）
            if case .add(let s) = event, !excludedSystemIds().contains(s.id) {
                let needsPrime = !primeUidSet.contains(s.id)
                let needsProfile = conversationProfiles[s.id] == nil
                if needsPrime || needsProfile {
                    Task { await self.refreshIncremental(for: [s.id], prime: needsPrime, profile: needsProfile) }
                }
            }
        default:
            break
        }
    }

    // MARK: - 置顶 / 删除（乐观更新 + 失败回滚）

    func setStickTop(sessionId: String, isTop: Bool) async {
        guard !isDirectMessagesSuspended else { return }
        guard case .loaded(let current) = state else { return }

        let optimistic = current.map { s -> MessageSession in
            guard s.id == sessionId else { return s }
            return MessageSession(id: s.id, peerNickname: s.peerNickname, peerAvatarURL: s.peerAvatarURL,
                                  lastMessage: s.lastMessage, lastMessageTimestamp: s.lastMessageTimestamp,
                                  unreadCount: s.unreadCount, isTop: isTop, ext: s.ext)
        }
        state = .loaded(optimistic)

        do {
            try await provider.setStickTop(sessionId: sessionId, isTop: isTop)
        } catch {
            guard !isDirectMessagesSuspended else { return }
            state = .loaded(current)
            logger.notice("[MessageStore] setStickTop rollback \(sessionId, privacy: .private) isTop=\(isTop, privacy: .public)")
        }
    }

    func delete(sessionId: String) async {
        guard !isDirectMessagesSuspended else { return }
        guard case .loaded(let current) = state else { return }
        let filtered = current.filter { $0.id != sessionId }
        state = .loaded(filtered)
        // v5.4 缓存审计补漏 G4：联动清对应 profile 和 prime 集合，避免孤儿累积。
        // 用户与同一 uid 重新对话时，delegate .add 事件走 needsProfile==true 分支会自动重拉。
        conversationProfiles.removeValue(forKey: sessionId)
        primeUidSet.remove(sessionId)

        do {
            try await provider.delete(sessionId: sessionId)
        } catch {
            guard !isDirectMessagesSuspended else { return }
            state = .loaded(current)
            logger.notice("[MessageStore] delete rollback \(sessionId, privacy: .private)")
        }
    }

    /// 清空指定分类下所有会话（对齐 H5 `news/index.vue:showEmpty` → `deleteSessionsByList`）。
    /// - `.flame` / `.prime` / `.stranger` 里显示的所有 P2P 会话逐条 delete；系统入口（Station/Notification/Admin）不受影响
    /// - 失败静默；每条走同款 provider.delete 有单独 rollback
    func clearCategory(_ cat: MessageSessionCategory) async {
        guard !isDirectMessagesSuspended else { return }
        let targets = sessions(in: cat)
        guard !targets.isEmpty else { return }
        logger.info("[MessageStore] clearCategory \(cat.rawValue, privacy: .public) count=\(targets.count, privacy: .public)")
        for s in targets {
            await delete(sessionId: s.id)
        }
    }

    /// 用户点击 Station 入口：标记已读 + 重算 unread（v4 新增）。
    func markStationRead() {
        guard !isDirectMessagesSuspended else { return }
        guard let mail = stationMail else { return }
        stationProvider.markRead(mail)
        recomputeSystemInbox()
    }

    // MARK: - Prime + Profile 增量拉取

    private func refreshIncremental(for uids: [String], prime: Bool, profile: Bool) async {
        let accessEpoch = directMessagesAccessEpoch
        guard isDirectMessagesAccessActive(accessEpoch) else { return }
        if prime {
            let newPrimes = await primeProvider.fetchPrime(yxAccIds: uids)
            guard isDirectMessagesAccessActive(accessEpoch) else { return }
            primeUidSet.formUnion(newPrimes)
        }
        if profile {
            let newProfiles = await profileProvider.fetch(yxAccIds: uids)
            guard isDirectMessagesAccessActive(accessEpoch) else { return }
            for (k, v) in newProfiles { conversationProfiles[k] = v }
        }
        // v5.1 修复：refreshIncremental 增量场景（新 session .add 到达）后**无条件**重赋 state，
        // 让 view 拿到最新 profile（含 onlineGroupStatus）。旧版 applyProfiles 相等检查只比
        // nickname/avatar 会漏 onlineGroupStatus 变化（用户报的 Q1 同源）。
        if case .loaded(let current) = state {
            state = .loaded(applyProfiles(to: current))
        }
    }

    // MARK: - 事件合并（内部纯逻辑）

    private func applyEvents(_ events: [MessageSessionEvent],
                             to current: [MessageSession]) -> [MessageSession] {
        var byId: [String: MessageSession] = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        for event in events {
            switch event {
            case .add(let s):
                byId[s.id] = s
            case .update(let s):
                byId[s.id] = s
            case .remove(let sid):
                byId.removeValue(forKey: sid)
                // v5.4 缓存审计补漏 G4：SDK 端 remove 事件同步清 profile/prime，避免孤儿累积。
                // 与 delete(sessionId:) 主动删同款处理；未来 .add 到达自动重拉。
                conversationProfiles.removeValue(forKey: sid)
                primeUidSet.remove(sid)
            }
        }
        return Array(byId.values)
    }

    // MARK: - v4e: 在线状态周期刷新

    /// 启动 20s 周期任务批拉在线状态（对齐 H5 `timingUpdateUserState` 10-30s 频率）。
    ///
    /// **触发点**：load() 完成后调；已有任务时先取消再启，避免重复。
    /// **对比 H5**：H5 走 5s WS 心跳里嵌套 `updateLimit=2/6`（10s/30s）；iOS 简化为独立 20s Task。
    /// **对比安卓**：安卓走 NIM subscribeOnlineStateEvent 推送；iOS 用轮询（H5 路径）成本更低。
    private func startOnlineStatusRefresh() {
        guard !isDirectMessagesSuspended else { return }
        onlineStatusRefreshTask?.cancel()
        attachBackgroundObservers()   // v5 F-1: 首次启动时挂后台观察者（幂等）
        onlineStatusRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.onlineStatusRefreshIntervalSec * 1_000_000_000)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                await self?.refreshOnlineStatus()
            }
        }
    }

    /// 单次批拉所有 sessions 在线状态（排除 notification/admin）；更新 conversationProfiles → 重构 sessions 触发 UI 刷。
    ///
    /// **策略**：20s 周期批量拉全 sessions 的 profile（batchSize=100 一次搞定 100 uid 以内）。
    /// **决策**：不做"仅可见"过滤 —— dev 阶段会话 <100 时全量与可见都是 1 request，收益 0%；
    /// SwiftUI TabView(.page) 3 tag 预建 + MainTabView keep-alive 三层容器让 onAppear "可见"语义失真；
    /// 快速滚动无 debounce 会反向恶化为 N 次单点 API 突刺。真正优化路径是云信 NIMSubscribeManager 推送（Android 已用），留 J 期评估。
    private func refreshOnlineStatus() async {
        let accessEpoch = directMessagesAccessEpoch
        guard isDirectMessagesAccessActive(accessEpoch) else { return }
        guard case .loaded(let sessions) = state, !sessions.isEmpty else { return }
        let excludedIds = excludedSystemIds()
        let uids = sessions.map(\.id).filter { !excludedIds.contains($0) }
        guard !uids.isEmpty else { return }
        let newProfiles = await profileProvider.fetch(yxAccIds: uids)
        guard isDirectMessagesAccessActive(accessEpoch) else { return }

        // v5.1 修复：以 profile 是否变化（含 onlineGroupStatus）作为重赋 state 的判据。
        // 旧版用 applyProfiles 后 sessions 数组相等检查，只比 nickname/avatar，onlineGroupStatus
        // 变化时误判"无变化"→ state 不重赋 → view 拿不到最新 profile → 绿灰点不刷（用户报的 Q1）。
        var hasChange = false
        for (k, v) in newProfiles {
            if conversationProfiles[k] != v {
                conversationProfiles[k] = v
                hasChange = true
            }
        }
        if hasChange, case .loaded(let current) = state {
            state = .loaded(applyProfiles(to: current))
        }
        logger.debug("🟣 [MessageStore] online refresh count=\(newProfiles.count, privacy: .public) changed=\(hasChange, privacy: .public)")
    }

    // MARK: - v5.5 空闲清理机制（bubbly-leaping-comet plan）
    //
    // `performIdleCleanup()`（读 CallStore.shared）+ AutoOfflineMonitor sink 挂载见
    // `MessageSessionStore+IdleCleanup.swift` extension（不入 HilyTests）。
    // 本方法为纯逻辑核心，`internal` 便于单测直接注入 `activeCallPeerId`。

    /// 实际清理逻辑（`internal` 便于单测直接注入 activeCallPeerId）。
    /// 规则见 `docs/plan` 的 bubbly-leaping-comet plan：
    /// - 规则 A：`lastMessageTimestamp < now - 30d` 且未命中保护清单 → 清
    /// - 规则 B：A 后仍 > 200 且最旧一条 < now - 15d → LRU 清到 200；最旧 ≥ 15 天则 skip
    /// - 保护清单：置顶 / 系统账号 (`excludedSystemIds()`) / Prime / Flame / 未读未超 30 天 / 通话中对端
    func performIdleCleanupWithProtection(activeCallPeerId: String?) async {
        guard !isDirectMessagesSuspended else { return }
        guard !isCleaningUp else {
            logger.debug("[Cleanup] skipped: isCleaningUp=true")
            return
        }
        guard case .loaded(let current) = state, !current.isEmpty else {
            logger.debug("[Cleanup] skipped: state not loaded or empty")
            return
        }

        isCleaningUp = true
        defer { isCleaningUp = false }

        let start = Date()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let staleThreshold = now - Self.cleanupStaleThresholdMs
        let ruleBAgeThreshold = now - Self.cleanupCountLimitMinAgeMs

        let systemIds = excludedSystemIds()
        let protectedCount = current.filter {
            isProtected($0, activeCallPeerId: activeCallPeerId, systemIds: systemIds, now: now)
        }.count
        logger.info("[Cleanup] start sessions=\(current.count, privacy: .public) protected=\(protectedCount, privacy: .public)")

        // 规则 A：30 天陈旧
        var idsToRemove: Set<String> = []
        for s in current where !isProtected(s, activeCallPeerId: activeCallPeerId, systemIds: systemIds, now: now) {
            if s.lastMessageTimestamp < staleThreshold {
                idsToRemove.insert(s.id)
            }
        }
        let countA = idsToRemove.count
        logger.info("[Cleanup] ruleA(30d) removed=\(countA, privacy: .public)")

        // 规则 B：200 数量上限 LRU（附加"最旧必须 <15 天"）
        var countB = 0
        var skipReason: String?
        let afterA = current.filter { !idsToRemove.contains($0.id) }
        if afterA.count > Self.cleanupCountLimit {
            let candidates = afterA
                .filter { !isProtected($0, activeCallPeerId: activeCallPeerId, systemIds: systemIds, now: now) }
                .sorted { $0.lastMessageTimestamp < $1.lastMessageTimestamp }
            if let oldest = candidates.first, oldest.lastMessageTimestamp >= ruleBAgeThreshold {
                skipReason = "oldest within 15d"
            } else {
                var needed = afterA.count - Self.cleanupCountLimit
                for s in candidates where needed > 0 {
                    idsToRemove.insert(s.id)
                    needed -= 1
                    countB += 1
                }
            }
        }
        logger.info("[Cleanup] ruleB(200/15d) removed=\(countB, privacy: .public) skipReason=\(skipReason ?? "-", privacy: .public)")

        guard !idsToRemove.isEmpty else {
            logger.info("[Cleanup] done removed=0 remaining=\(current.count, privacy: .public) elapsed=0ms")
            return
        }

        // 批量更新：一次 state 变化 + 一次 profile/prime 清 + 逐条 SDK delete
        let filtered = current.filter { !idsToRemove.contains($0.id) }
        state = .loaded(filtered)
        for id in idsToRemove {
            conversationProfiles.removeValue(forKey: id)
            primeUidSet.remove(id)
        }
        // 无需 recomputeSystemInbox()：保护清单 #2 排除系统账号，idsToRemove 永不含它们

        for id in idsToRemove {
            do {
                try await provider.delete(sessionId: id)
            } catch {
                logger.notice("[Cleanup] delete \(id, privacy: .private) failed: \(String(describing: error), privacy: .public)")
                // 单条失败不回滚：cleanup 是尽力删，其他已删的不重新加回
            }
        }

        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        logger.info("[Cleanup] done removed=\(idsToRemove.count, privacy: .public) remaining=\(filtered.count, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms")
    }

    /// 保护清单集中判定。任一命中即返 true。
    /// `now` 由 caller 传入统一时间基准（避免同一次 cleanup 内多次调用各自 `Date()` 造成毫秒级漂移）。
    private func isProtected(_ session: MessageSession,
                             activeCallPeerId: String?,
                             systemIds: Set<String>,
                             now: Int64) -> Bool {
        if session.isTop { return true }                                          // #1 置顶
        if systemIds.contains(session.id) { return true }                          // #2 系统类账号（客服 + 通知）
        if primeUidSet.contains(session.id) { return true }                        // #3 Prime
        if session.ext.isFlameByExt { return true }                                // #4 Flame
        if session.unreadCount > 0                                                 // #5 未读且未超 30 天
            && session.lastMessageTimestamp >= now - Self.cleanupStaleThresholdMs {
            return true
        }
        if let peer = activeCallPeerId, session.id == peer { return true }         // #6 通话中对端
        return false
    }

    /// P2P 权限变化入口。暂停时清内存态并停止轮询；恢复时只在 IM 已同步后重新加载。
    /// `SessionStore` 与 MainTabView 均会调用它，但重复调用保持幂等。
    func setDirectMessagesCapabilityEnabled(_ enabled: Bool) {
        if enabled {
            guard isDirectMessagesSuspended else { return }
            isDirectMessagesSuspended = false
            directMessagesAccessEpoch &+= 1
            logger.info("🟢 [MessageStore] P2P capability resumed")
            guard isIMSynced else { return }
            Task { @MainActor [weak self] in
                await self?.load()
            }
            return
        }

        guard !isDirectMessagesSuspended else { return }
        isDirectMessagesSuspended = true
        directMessagesAccessEpoch &+= 1
        resetDirectMessagesData()
        logger.info("🟢 [MessageStore] P2P capability suspended")
    }

    /// 登出/切账号兼容入口。Store 是 `.shared` 单例不 deinit，清空必须同时阻止后续 SDK
    /// connection 事件把会话重新拉回。
    func clear() {
        setDirectMessagesCapabilityEnabled(false)
    }

    private func resetDirectMessagesData() {
        onlineStatusRefreshTask?.cancel()
        onlineStatusRefreshTask = nil
        detachBackgroundObservers()
        conversationProfiles.removeAll()
        primeUidSet.removeAll()
        flameUserIdSet.removeAll()   // H-2 v2: 清 Flame 通道 B（跨账号 followList 缓存）
        stationMail = nil
        systemInboxEntries = []
        pendingUpdates.removeAll()
        state = .idle
    }

    private func isDirectMessagesAccessActive(_ epoch: UInt) -> Bool {
        !isDirectMessagesSuspended && directMessagesAccessEpoch == epoch
    }

    /// v5 F-1: 切后台 pause + 回前台 restart 观察者（对齐 CLAUDE.md v5.3.2 "后台静默 + 回前台冷却"）
    private func attachBackgroundObservers() {
        guard backgroundObserver == nil else { return }
        let center = NotificationCenter.default
        backgroundObserver = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isDirectMessagesSuspended else { return }
                self.onlineStatusRefreshTask?.cancel()
                self.onlineStatusRefreshTask = nil
                self.logger.debug("🟣 [MessageStore] background → pause 20s task")
            }
        }
        foregroundObserver = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isDirectMessagesSuspended else { return }
                if case .loaded = self.state {
                    self.startOnlineStatusRefresh()
                    self.logger.debug("🟣 [MessageStore] foreground → restart 20s task")
                    // 回前台立即拉一次，避免用户等 20s 才看到最新状态
                    await self.refreshOnlineStatus()
                }
            }
        }
    }

    private func detachBackgroundObservers() {
        let center = NotificationCenter.default
        if let obs = backgroundObserver { center.removeObserver(obs); backgroundObserver = nil }
        if let obs = foregroundObserver { center.removeObserver(obs); foregroundObserver = nil }
    }

    deinit {
        onlineStatusRefreshTask?.cancel()
        let center = NotificationCenter.default
        if let obs = backgroundObserver { center.removeObserver(obs) }
        if let obs = foregroundObserver { center.removeObserver(obs) }
    }

    /// 用 `conversationProfiles` 缓存覆盖 sessions 的 peerNickname / peerAvatarURL（v4d）。
    ///
    /// **触发点**：load 完 profiles、增量 add 完 profiles、任何 sessions 重构的地方；
    /// 覆盖策略：profile 有值就用 profile（H5 优先信主动拉的画像），缺则保持原值（Adapter 从 SDK 缓存的兜底）。
    private func applyProfiles(to sessions: [MessageSession]) -> [MessageSession] {
        return sessions.map { s in
            guard let p = conversationProfiles[s.id] else { return s }
            let newNick = p.nickname?.isEmpty == false ? p.nickname! : s.peerNickname
            let newAvatar = p.icon?.isEmpty == false ? p.icon : s.peerAvatarURL
            if newNick == s.peerNickname && newAvatar == s.peerAvatarURL { return s }
            return MessageSession(
                id: s.id,
                peerNickname: newNick,
                peerAvatarURL: newAvatar,
                lastMessage: s.lastMessage,
                lastMessageTimestamp: s.lastMessageTimestamp,
                unreadCount: s.unreadCount,
                isTop: s.isTop,
                ext: s.ext
            )
        }
    }

    // MARK: - v4：系统消息 3 入口派生

    /// 排除常规 3 tab 的 session id 集合（notification + admin）。
    private func excludedSystemIds() -> Set<String> {
        var s: Set<String> = [AppConfig.notificationYxAccId]
        if let cid = customerServiceStore.customerYxAccId, !cid.isEmpty {
            s.insert(cid)
        }
        return s
    }

    /// 重算 Flame 顶部 3 入口（固定顺序：Station / Notification / Admin）。
    ///
    /// 数据来源：
    /// - Station: `stationMail`（HTTP 拉取，可能为 nil）
    /// - Notification: `state.loaded` 中 id == `notificationYxAccId` 的 session
    /// - Admin: `state.loaded` 中 id == `customerYxAccId` 的 session
    ///
    /// **3 入口永远显示**（无数据时 preview/时间/unread=0，UI 空态兜底）。
    private func recomputeSystemInbox() {
        guard !isDirectMessagesSuspended else { return }
        let all: [MessageSession] = {
            if case .loaded(let s) = state { return s }
            return []
        }()

        var entries: [SystemInboxEntry] = []

        // 1. Station
        if let mail = stationMail {
            entries.append(SystemInboxEntry(
                id: "station",
                kind: .station,
                preview: mail.mailTitle,
                updateTime: 0,
                unread: stationProvider.isUnread(mail) ? 1 : 0
            ))
        } else {
            entries.append(SystemInboxEntry(
                id: "station",
                kind: .station,
                preview: "",
                updateTime: 0,
                unread: 0
            ))
        }

        // 2. Notification session
        let notifySession = all.first(where: { $0.id == AppConfig.notificationYxAccId })
        entries.append(SystemInboxEntry(
            id: "notification",
            kind: .notification,
            preview: notifySession?.lastMessage ?? "",
            updateTime: notifySession?.lastMessageTimestamp ?? 0,
            unread: notifySession?.unreadCount ?? 0
        ))

        // 3. Admin session
        let adminSession: MessageSession? = {
            guard let cid = customerServiceStore.customerYxAccId, !cid.isEmpty else { return nil }
            return all.first(where: { $0.id == cid })
        }()
        entries.append(SystemInboxEntry(
            id: "admin",
            kind: .admin,
            preview: adminSession?.lastMessage ?? "",
            updateTime: adminSession?.lastMessageTimestamp ?? 0,
            unread: adminSession?.unreadCount ?? 0
        ))

        systemInboxEntries = entries
    }
}
