import Foundation
import SwiftUI
import Combine
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "AnchorInfoStore")

/// 主播本人信息单例：跨 view 共享 + 持久化 + Task.detached 隔离请求生命周期。
///
/// 为什么是 singleton 而非 view-owned `@StateObject`：
/// - iOS 系统 TabView 在内存压力 / view tree 变更时可能销毁未显示 view 的 @StateObject，
///   导致 ProfileView 重新进入时数据被清空、又重新拉取
/// - `.refreshable` / `.task` 启动的 await 在 view cancel 时会取消 URLSession 任务
///   （报 `NSURLErrorCancelled -999`）
/// - 主播信息多处复用（Profile / Work 头部 / Settings / 直播开播默认值），需要单一来源
///
/// 设计：
/// - `info` (来自 /api/anchor/userInfo) 主写，`mine` (来自登录响应 LoginResult) 兜底
/// - 2026-07-16：`mine` 不再走 `/api/user/getUserInfo`（后端 404），改为 `hydrateFromLogin(_:)` 由
///   SessionStore.applyLogin / load 直接注入，对齐 H5 `loginSuccess → setMineInfo(res)` 语义
/// - 派生 UI 字段（displayName / userId / ratePerMin 等）统一在本 store 计算
/// - `loadIfNeeded()` 首次拉一次 → `hasLoadedOnce=true` 之后不重拉
/// - `refresh()` 用户主动触发（下拉 / 资料编辑后）强制刷新
/// - 请求通过 `Task.detached` 启动，view cancel 不影响请求继续完成
/// - 启动时从 UserDefaults JSON 恢复，每次 reload 成功后保存
@MainActor
final class AnchorInfoStore: ObservableObject {

    static let shared = AnchorInfoStore()

    enum LoadState: Equatable {
        case idle, loading, loaded, error(String)

        var isLoading: Bool { if case .loading = self { return true } else { return false } }
        var errorMessage: String? { if case .error(let m) = self { return m } else { return nil } }
    }

    // MARK: - 状态
    @Published private(set) var info: AnchorInfo?
    @Published private(set) var mine: AnchorInfo?
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var hasLoadedOnce: Bool = false

    /// 社交数（跨页同步源；FollowListViewModel.toggleFollow 后通过 NotificationCenter 增减）
    @Published var followingCount: Int = 0
    @Published var followersCount: Int = 0
    @Published var friendsCount: Int = 0

    /// 主播礼物墙（H5 mine/index.vue:92 独立接口 `/api/anchor/getGiftWallList`）。
    /// 拉取失败为非致命——空数组即触发 UI 空态；不阻塞 hasLoadedOnce。
    @Published private(set) var giftWallList: [GiftItem] = []

    // MARK: - 持久化 & 并发控制
    /// v3（2026-07-09 Profile Album/Gifts 对齐）：CachedSnapshot 加 `picList` + `giftWallList`。
    /// 老 v2 缓存 decode 到新 schema 会整个失败（picList 缺 → optional 兼容；giftWallList 缺 → decodeIfPresent）
    /// —— **实际不需要升 key** 也能兼容（optional + decodeIfPresent 自然回落 nil/[]）；但 giftWallList 若从 v2
    /// 恢复会永远空数组，须走一次 refresh 补 → 升 key 让冷启动强制 loading→refresh 更彻底一致。
    /// v2（2026-07-07 I-spec-用户资料编辑页 §2.2）：`AnchorInfo.greetMsgs` schema 从 `[String]?`
    /// 升级为 `[GreetMsg]?` 含 id 支持编辑页删除 diff。老 v1 缓存 decode 到新 schema 会整个
    /// CachedSnapshot decode 失败 → 升 key 让老快照自然废弃，冷启动闪一次 loading 后 refresh。
    /// v5：好友数改用 H5 / Android 权威字段 friendNum，旧快照必须强制刷新。
    private let cacheKey = "anchorInfoStore.v5"
    private static let obsoleteCacheKeys = ["anchorInfoStore.v3", "anchorInfoStore.v4"]
    private var inflightTask: Task<Void, Never>?
    private var followObserver: NSObjectProtocol?
    private var permissionCancellables = Set<AnyCancellable>()

    /// 代际 token：`clear()` 递增，`performReload` 起点快照，`doReload` 落地前对比。
    /// A logout 时正在飞的 detached task 完成时 epoch mismatch → 丢弃结果不写 store/keychain，
    /// 避免"A 老 task 覆盖 B 新数据 + hasLoadedOnce=true 让新 loadIfNeeded 短路"的竞态污染。
    /// 对齐 `BlocklistViewModel` 同款代际 token 模式。
    private var reloadEpoch: Int = 0

    private init() {
        // 不读取旧快照：它没有 friendNum，Profile 会继续显示错误的好友数。
        for key in Self.obsoleteCacheKeys {
            KeychainStore.remove(for: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        loadFromDisk()
        followObserver = NotificationCenter.default.addObserver(
            forName: .followRelationChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard
                let userInfo = note.userInfo,
                let flag = userInfo["followFlag"] as? Int
            else { return }
            Task { @MainActor in
                guard let self else { return }
                self.followingCount = max(0, self.followingCount + (flag == 1 ? 1 : -1))
                self.saveToDisk()
            }
        }
        observeVirtualItemsPermission()
    }

    deinit {
        if let followObserver { NotificationCenter.default.removeObserver(followObserver) }
    }

    // MARK: - 公共 API

    /// 首次加载（hasLoadedOnce=true 直接返回）。`.task` 调用入口。
    func loadIfNeeded() async {
        if hasLoadedOnce { return }
        if let inflightTask {
            await inflightTask.value
            return
        }
        await performReload()
    }

    /// 强制刷新（下拉 / 编辑资料后）。
    /// 下拉刷新场景：先把当前 Profile 关联的图片缓存全部 invalidate，
    /// 让 CachedAsyncImage 重新走网络拉到最新图（用户改了头像 / 相册不会显示老图）。
    func refresh() async {
        if let inflightTask {
            await inflightTask.value
            return
        }
        invalidateImageCaches()
        await performReload()
    }

    /// 2026-07-16：从登录响应直接注入 `mine`，对齐 H5 `loginSuccess → setMineInfo(res)`。
    /// SessionStore.applyLogin（登录成功）+ SessionStore.load（冷启动 restore）双入口调用；
    /// 后端不存在 `/api/user/getUserInfo`，登录响应本身是 mine 权威来源。
    func hydrateFromLogin(_ result: LoginResult) {
        mine = AnchorInfo.fromLoginResult(result)
        saveToDisk()
    }

    /// 虚拟道具页的 Chat Skin 乐观更新入口。
    ///
    /// 对齐 H5 `virtualProps/index.vue`：装备结果立即写入 `mineInfo.chatBubble`，使后续私聊、
    /// 直播公屏、派对房和通话消息使用同一份当前皮肤；服务端失败时由 PropsInventoryStore 回滚。
    func applyChatBubble(_ rawURL: String?) {
        // 登录态先于 Profile 缓存 hydrate 的短暂窗口内，仍需让装备立即生效。
        guard var updatedMine = mine ?? SessionStore.shared.user.map(AnchorInfo.fromLoginResult) else {
            logger.warning("applyChatBubble skipped: no authenticated anchor")
            return
        }
        let trimmed = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updatedMine.chatBubble = trimmed.isEmpty ? nil : trimmed
        mine = updatedMine
        saveToDisk()
    }

    /// 列出本 Profile 关联的所有图片 URL，从 ImageCache + URLCache 中清除。
    /// 只清"持久写入过"的本人资源（头像/相册/视频封面/礼物图），不影响他人头像。
    private func invalidateImageCaches() {
        var urls: [URL] = []
        if let iconURL { urls.append(iconURL) }
        urls.append(contentsOf: photos.compactMap { $0.url.flatMap(URL.init(string:)) })
        urls.append(contentsOf: videos.compactMap { ($0.coverUrl ?? $0.url).flatMap(URL.init(string:)) })
        urls.append(contentsOf: giftList.compactMap { $0.iconUrl.flatMap(URL.init(string:)) })
        urls.append(contentsOf: giftWallList.compactMap { $0.iconUrl.flatMap(URL.init(string:)) })
        guard !urls.isEmpty else { return }
        ImageCache.shared.invalidate(urls)
        logger.info("invalidated \(urls.count) image cache entries")
    }

    /// 登出时清空：SessionStore.logout 调用。
    func clear() {
        // 先递增 epoch 让已发出的 detached reload 失效：Task.cancel() 只 mark、doReload 不
        // check isCancelled，唯一可靠的丢弃入口是让 doReload 完成时 guard epoch mismatch。
        reloadEpoch += 1
        inflightTask?.cancel()
        inflightTask = nil
        info = nil
        mine = nil
        loadState = .idle
        hasLoadedOnce = false
        followingCount = 0
        followersCount = 0
        friendsCount = 0
        giftWallList = []
        // P2-16：v2 在 Keychain；v1 残留也一并清（迁移期保险）
        KeychainStore.remove(for: cacheKey)
        UserDefaults.standard.removeObject(forKey: cacheKey)
        // 防御性双清：SessionStore.logout 也会调 ImageCache.clear()，
        // 这里再补一刀确保任何场景下 clear() 都不残留图片
        ImageCache.shared.clear()
    }

    // MARK: - 拉取

    /// 启动 detached task 隔离请求生命周期：view cancel 不影响请求完成。
    ///
    /// **epoch 语义**：捕获当前 `reloadEpoch` 传给 `doReload`；期间 `clear()` 递增 epoch 后
    /// 老 task 完成时 guard mismatch 直接 discard，避免"A logout 后 A 老 task 覆盖 B 新数据"。
    private func performReload() async {
        let epoch = reloadEpoch
        let task = Task.detached { @MainActor [self] in
            await doReload(epoch: epoch)
        }
        inflightTask = task
        await task.value
        // 若期间 clear() 递增了 epoch，`inflightTask` 可能已被后续 clear / performReload
        // 覆盖为 nil 或 B task，盲清会误清别人——用 epoch 对比守卫
        if epoch == reloadEpoch {
            inflightTask = nil
        }
    }

    private func doReload(epoch: Int) async {
        // 起点守卫：detached task 排 MainActor 期间 clear() 已递增 epoch → 整段丢弃不做任何写入
        guard epoch == self.reloadEpoch else {
            logger.info("doReload skipped at start: epoch=\(epoch) current=\(self.reloadEpoch)")
            return
        }
        loadState = .loading

        // 2026-07-16：`mine` 由 `hydrateFromLogin` 从登录响应直接注入，doReload 不再拉 `/api/user/getUserInfo`
        // （后端返 404）。剩余 2 接口全 non-fatal——未审核账号 getAnchorInfo 也可能返错，允许 info nil，
        // 派生 UI 字段 displayName/userId/iconURL 走 info ?? mine ?? SessionStore 兜底。
        async let anchorTask: AnchorInfo? = {
            do { return try await ProfileService.getAnchorInfo() }
            catch {
                logger.warning("getAnchorInfo failed (non-fatal): \(String(describing: error))")
                return nil
            }
        }()
        // 礼物墙独立接口（H5 mine/index.vue:92）。107 的 Party-only 会话没有
        // 虚拟道具能力，连同旧缓存一起收口，不能只靠 Profile UI 隐藏入口。
        let shouldLoadGiftWall = canAccessVirtualItems
        if !shouldLoadGiftWall {
            clearGiftWallForDisabledVirtualItems()
        }
        async let giftTask: [GiftItem] = {
            guard shouldLoadGiftWall else { return [] }
            do { return try await ProfileService.getGiftWallList() }
            catch {
                logger.warning("getGiftWallList failed (non-fatal): \(String(describing: error))")
                return []
            }
        }()

        let anchor = await anchorTask
        let giftWall = await giftTask

        // API await 期间可能被 clear() 递增 epoch（用户登出竞态）——丢弃全部写入，
        // 不写 info/mine/social/loadState/hasLoadedOnce，也不 saveToDisk（否则 keychain 会被 A 数据污染，
        // 冷启动 loadFromDisk 又恢复 A 让 hasLoadedOnce=true 短路新 loadIfNeeded）
        guard epoch == self.reloadEpoch else {
            logger.info("doReload result discarded: epoch=\(epoch) current=\(self.reloadEpoch)")
            return
        }

        self.info = anchor
        self.giftWallList = canAccessVirtualItems ? giftWall : []
        // `mine` 保留 hydrateFromLogin 注入值，不在此重写

        // 社交数从接口字段直接写入（覆盖；用户操作的增减在 Notification 收到时再叠加）；
        // mine (from LoginResult) 无社交计数字段，只从 anchor 取
        if let n = anchor?.upsNum { self.followingCount = n }
        if let n = anchor?.fansNum { self.followersCount = n }
        if let n = anchor?.friendNum ?? anchor?.friendsNum { self.friendsCount = n }

        // 2 接口全 nil/空 时保留 .error 语义,让 ProfileView 显 error banner + Retry(避免用户被静默错误困住);
        // 至少一个成功 → .loaded(下游派生 UI 走 info ?? mine 兜底)
        if anchor == nil && giftWall.isEmpty {
            loadState = .error(String(format: L10n.profileLoadFailedFormat, "no data returned"))
        } else {
            loadState = .loaded
        }
        hasLoadedOnce = true
        saveToDisk()
        logger.info("reload OK userId=\(anchor?.userId ?? -1) anchorMerged=\(anchor != nil) giftWall=\(giftWall.count)")
    }

    // MARK: - 派生 UI 字段（info 优先 / mine 兜底 / SessionStore 兜底）

    var displayName: String {
        Self.firstNonEmpty(info?.nickname, mine?.nickname, SessionStore.shared.user?.nickname) ?? ""
    }

    /// 当前主播穿戴的 Chat Skin。`mine` 与 H5 `mineInfo` 同源；仅在 mine 整体尚未 hydrate 时，
    /// 才用资料接口回退。这样卸下皮肤写入 nil 后不会被旧的 info 快照重新覆盖。
    var currentChatBubble: String? {
        if let mine {
            let bubble = mine.chatBubble?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return bubble.isEmpty ? nil : bubble
        }
        return Self.firstNonEmpty(info?.chatBubble)
    }

    /// 守护气泡的来源等级。主播在自己的直播房不是自己的守护者，公屏消息需据此隐藏 Chat Skin。
    var currentChatBubbleGuardianLevel: Int {
        mine?.chatBubbleGuardianLevel ?? info?.chatBubbleGuardianLevel ?? 0
    }

    var userId: String {
        if let uid = info?.userId ?? mine?.userId { return String(uid) }
        if let uid = SessionStore.shared.user?.userId { return String(uid) }
        return ""
    }

    var ageText: String {
        let age = info?.age ?? mine?.age ?? 0
        return age > 0 ? String(age) : ""
    }

    var countryFlag: String {
        let code = (info?.countryCode ?? mine?.countryCode) ?? ""
        return code.isEmpty ? "" : Self.flagEmoji(from: code)
    }

    /// H5 mine 顶部直接展示 countryId；接口未返回时再回退 ISO countryCode。
    var countryText: String {
        Self.firstNonEmpty(
            info?.countryId,
            info?.countryCode,
            mine?.countryId,
            mine?.countryCode
        ) ?? ""
    }

    var tierLabel: String {
        if let n = info?.userLevel, !n.isEmpty { return n }
        if let n = info?.levelName, !n.isEmpty { return n }
        if let lvl = info?.level { return Self.tierName(forLevel: lvl) }
        if let n = mine?.userLevel, !n.isEmpty { return n }
        if let n = mine?.levelName, !n.isEmpty { return n }
        if let lvl = mine?.level { return Self.tierName(forLevel: lvl) }
        return ""
    }

    // H5 mine 顶部用 videoPrice；兼容 iOS 旧模型中的 callPrice。
    var ratePerMin: Int {
        info?.videoPrice ?? info?.callPrice ?? mine?.videoPrice ?? mine?.callPrice ?? 0
    }

    var iconURL: URL? {
        let s = info?.icon ?? mine?.icon ?? SessionStore.shared.user?.icon ?? ""
        return s.isEmpty ? nil : URL(string: s)
    }

    var bio: String {
        Self.firstNonEmpty(info?.signature, mine?.signature) ?? ""
    }

    /// 相册照片：真接口用 `picList` 单一数组（mediaType 1=图 2=视频）分流；
    /// `pictures`/`videos` 是 iOS 侧臆想字段实测不返，保留仅作 legacy fallback（H5 蓝本 mine/index.vue:259）。
    var photos: [MediaAsset] {
        let list = info?.picList ?? mine?.picList ?? []
        let fromPicList = list.filter { $0.mediaType == 1 }.map(Self.mediaAsset(from:))
        if !fromPicList.isEmpty { return fromPicList }
        return info?.pictures ?? mine?.pictures ?? []
    }
    var videos: [MediaAsset] {
        let list = info?.picList ?? mine?.picList ?? []
        let fromPicList = list.filter { $0.mediaType == 2 }.map(Self.mediaAsset(from:))
        if !fromPicList.isEmpty { return fromPicList }
        return info?.videos ?? mine?.videos ?? []
    }
    /// 礼物墙：优先独立接口 `giftWallList`（H5 mine/index.vue:92）；
    /// 兜底 anchor/mine 里可能夹带的 giftList（后端偶尔混发时不丢）。
    var giftList: [GiftItem] {
        guard canAccessVirtualItems else { return [] }
        return !giftWallList.isEmpty ? giftWallList
            : (info?.giftList ?? mine?.giftList ?? [])
    }

    /// AnchorPicItem → MediaAsset 桥接（视频取 videoCover 作 coverUrl，图片 nil）
    private static func mediaAsset(from item: AnchorPicItem) -> MediaAsset {
        MediaAsset(
            assetId: item.assetId,
            url: item.mediaUrl,
            coverUrl: item.mediaType == 2 ? item.videoCover : nil,
            vaild: item.vaild,
            createTime: nil
        )
    }

    // MARK: - 持久化

    private struct CachedSnapshot: Codable {
        let info: AnchorInfo?
        let mine: AnchorInfo?
        let followingCount: Int
        let followersCount: Int
        let friendsCount: Int
        let giftWallList: [GiftItem]?     // v3 加；老快照 decode 时缺此字段 → nil，applySnapshot 落 []
    }

    /// P2-16：从 UserDefaults 迁 Keychain（ThisDeviceOnly + Synchronizable=false，
    /// 与 SessionStore.v2 同款）。AnchorInfo 含 nickname / age / signature / 相册 URL / videos /
    /// giftList / callPrice 等 PII + 商业字段，明文写 UserDefaults 会被：
    ///   1) 越狱设备 sandbox bypass 直读
    ///   2) iTunes/Finder 备份未启用 "Encrypt local backup" 时明文导出
    ///   3) iCloud 备份恢复到新设备还原（与 ThisDeviceOnly 约定相反）
    /// 迁移路径：v2 优先；v1 命中时搬迁到 v2 后清空（一次性）。
    private func loadFromDisk() {
        // v2: Keychain
        if let data = KeychainStore.getData(for: cacheKey),
           let snap = try? JSONDecoder().decode(CachedSnapshot.self, from: data) {
            applySnapshot(snap, source: "keychain")
            return
        }
        // v1 → v2 一次性迁移：必须 verify Keychain 写入成功**后**再删 v1，
        // 否则 Keychain 写失败（极端：item 超出 Keychain limit / device 异常）会导致
        // 缓存数据丢失，下次启动冷启动 loading 状态恶化。
        if let legacy = UserDefaults.standard.data(forKey: cacheKey),
           let snap = try? JSONDecoder().decode(CachedSnapshot.self, from: legacy) {
            if KeychainStore.setData(legacy, for: cacheKey) {
                UserDefaults.standard.removeObject(forKey: cacheKey)
            }
            applySnapshot(snap, source: "migrated-from-userdefaults")
            return
        }
    }

    private func applySnapshot(_ snap: CachedSnapshot, source: String) {
        info = snap.info
        mine = snap.mine
        followingCount = snap.followingCount
        followersCount = snap.followersCount
        friendsCount = snap.friendsCount
        giftWallList = snap.giftWallList ?? []
        if info != nil || mine != nil {
            hasLoadedOnce = true
            loadState = .loaded
            logger.info("loadFromDisk OK source=\(source, privacy: .public) userId=\(self.info?.userId ?? -1, privacy: .private)")
        }
    }

    private func saveToDisk() {
        let snap = CachedSnapshot(
            info: info, mine: mine,
            followingCount: followingCount,
            followersCount: followersCount,
            friendsCount: friendsCount,
            giftWallList: giftWallList
        )
        if let data = try? JSONEncoder().encode(snap) {
            KeychainStore.setData(data, for: cacheKey)
        }
    }

    // MARK: - Virtual item permission

    /// Bridge 首次绑定 SessionStore 前保留 userType 映射兜底：正常主播不会因启动时序漏拉
    /// 礼物墙，107 则从登录响应落地起就被拒绝。未登录时一律不请求。
    private var canAccessVirtualItems: Bool {
        let permission = SelfPermissionBridge.shared
        if permission.isLoaded {
            return permission.canVirtualItems
        }
        guard SessionStore.shared.isLoggedIn else {
            return false
        }
        return !UserPermissionMapping.blocked(for: UserTypeExperience.fixedUserType).contains(.virtualItems)
    }

    /// 角色热切换时清掉独立礼物墙缓存。飞行中的 reload 在落地时会再次读取
    /// `canAccessVirtualItems`，不会把旧角色的结果重新写回内存。
    private func observeVirtualItemsPermission() {
        let permission = SelfPermissionBridge.shared
        permission.$isLoaded
            .combineLatest(permission.$canVirtualItems)
            .sink { [weak self] isLoaded, canVirtualItems in
                guard isLoaded, !canVirtualItems else { return }
                self?.clearGiftWallForDisabledVirtualItems()
            }
            .store(in: &permissionCancellables)
    }

    private func clearGiftWallForDisabledVirtualItems() {
        guard !giftWallList.isEmpty else { return }
        let urls = giftWallList.compactMap { $0.iconUrl.flatMap(URL.init(string:)) }
        giftWallList = []
        ImageCache.shared.invalidate(urls)
        saveToDisk()
    }

    // MARK: - Helpers

    /// ISO 两字母国家码 → Unicode regional indicator emoji。非法回落 🌐。
    ///
    /// **nonisolated**:纯函数无 actor state 访问,允许 UserCardService.decodeCard 等
    /// nonisolated context 调用,不给 decode 链路强加 @MainActor(会阻塞 main actor)。
    nonisolated static func flagEmoji(from countryCode: String) -> String {
        let trimmed = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count == 2 else { return "🌐" }
        let base: UInt32 = 0x1F1E6 - 0x41
        var result = ""
        for scalar in trimmed.unicodeScalars {
            guard (0x41...0x5A).contains(scalar.value),
                  let s = Unicode.Scalar(base + scalar.value) else { return "🌐" }
            result.append(Character(s))
        }
        return result
    }

    /// 数字段位 → 字面量（D/C/NEW/B/A/S/SS，待真机校验后端编码方式）
    static func tierName(forLevel level: Int) -> String {
        let names = ["D", "C", "NEW", "B", "A", "S", "SS"]
        guard level >= 0, level < names.count else { return String(level) }
        return names[level]
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for v in values { if let v, !v.isEmpty { return v } }
        return nil
    }
}
