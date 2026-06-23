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
/// - `info` (来自 /api/anchor/userInfo) 主写，`mine` (来自 /api/user/getUserInfo) 兜底
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

    // MARK: - 持久化 & 并发控制
    private let cacheKey = "anchorInfoStore.v1"
    private var inflightTask: Task<Void, Never>?
    private var followObserver: NSObjectProtocol?

    private init() {
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

    /// 列出本 Profile 关联的所有图片 URL，从 ImageCache + URLCache 中清除。
    /// 只清"持久写入过"的本人资源（头像/相册/视频封面/礼物图），不影响他人头像。
    private func invalidateImageCaches() {
        var urls: [URL] = []
        if let iconURL { urls.append(iconURL) }
        urls.append(contentsOf: photos.compactMap { $0.url.flatMap(URL.init(string:)) })
        urls.append(contentsOf: videos.compactMap { ($0.coverUrl ?? $0.url).flatMap(URL.init(string:)) })
        urls.append(contentsOf: giftList.compactMap { $0.iconUrl.flatMap(URL.init(string:)) })
        guard !urls.isEmpty else { return }
        ImageCache.shared.invalidate(urls)
        logger.info("invalidated \(urls.count) image cache entries")
    }

    /// 登出时清空：SessionStore.logout 调用。
    func clear() {
        inflightTask?.cancel()
        inflightTask = nil
        info = nil
        mine = nil
        loadState = .idle
        hasLoadedOnce = false
        followingCount = 0
        followersCount = 0
        friendsCount = 0
        UserDefaults.standard.removeObject(forKey: cacheKey)
        // 防御性双清：SessionStore.logout 也会调 ImageCache.clear()，
        // 这里再补一刀确保任何场景下 clear() 都不残留图片
        ImageCache.shared.clear()
    }

    // MARK: - 拉取

    /// 启动 detached task 隔离请求生命周期：view cancel 不影响请求完成。
    private func performReload() async {
        let task = Task.detached { @MainActor [self] in
            await doReload()
        }
        inflightTask = task
        await task.value
        inflightTask = nil
    }

    private func doReload() async {
        loadState = .loading
        do {
            async let anchorTask = ProfileService.getAnchorInfo()
            async let mineTask: AnchorInfo? = {
                do { return try await ProfileService.getMineInfo() }
                catch {
                    logger.warning("getMineInfo failed (non-fatal): \(String(describing: error))")
                    return nil
                }
            }()

            let anchor = try await anchorTask
            let mineInfo = await mineTask

            self.info = anchor
            self.mine = mineInfo

            // 社交数从接口字段直接写入（覆盖；用户操作的增减在 Notification 收到时再叠加）
            if let n = anchor.upsNum    ?? mineInfo?.upsNum    { self.followingCount = n }
            if let n = anchor.fansNum   ?? mineInfo?.fansNum   { self.followersCount = n }
            if let n = anchor.friendsNum ?? mineInfo?.friendsNum { self.friendsCount = n }

            loadState = .loaded
            hasLoadedOnce = true
            saveToDisk()
            logger.info("reload OK userId=\(anchor.userId ?? -1) mineMerged=\(mineInfo != nil)")
        } catch let e as APIError {
            loadState = .error(e.message)
            logger.error("reload APIError code=\(e.code) message=\(e.message)")
        } catch {
            let msg = String(format: L10n.profileLoadFailedFormat, error.localizedDescription)
            loadState = .error(msg)
            logger.error("reload error: \(String(describing: error))")
        }
    }

    // MARK: - 派生 UI 字段（info 优先 / mine 兜底 / SessionStore 兜底）

    var displayName: String {
        Self.firstNonEmpty(info?.nickname, mine?.nickname, SessionStore.shared.user?.nickname) ?? ""
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

    var tierLabel: String {
        if let n = info?.levelName, !n.isEmpty { return n }
        if let lvl = info?.level { return Self.tierName(forLevel: lvl) }
        if let n = mine?.levelName, !n.isEmpty { return n }
        if let lvl = mine?.level { return Self.tierName(forLevel: lvl) }
        return ""
    }

    var ratePerMin: Int { info?.callPrice ?? mine?.callPrice ?? 0 }

    var iconURL: URL? {
        let s = info?.icon ?? mine?.icon ?? SessionStore.shared.user?.icon ?? ""
        return s.isEmpty ? nil : URL(string: s)
    }

    var bio: String {
        Self.firstNonEmpty(info?.signature, mine?.signature) ?? ""
    }

    var photos: [MediaAsset] { info?.pictures ?? mine?.pictures ?? [] }
    var videos: [MediaAsset] { info?.videos ?? mine?.videos ?? [] }
    var giftList: [GiftItem] { info?.giftList ?? mine?.giftList ?? [] }

    // MARK: - 持久化

    private struct CachedSnapshot: Codable {
        let info: AnchorInfo?
        let mine: AnchorInfo?
        let followingCount: Int
        let followersCount: Int
        let friendsCount: Int
    }

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let snap = try? JSONDecoder().decode(CachedSnapshot.self, from: data) else { return }
        info = snap.info
        mine = snap.mine
        followingCount = snap.followingCount
        followersCount = snap.followersCount
        friendsCount = snap.friendsCount
        if info != nil || mine != nil {
            hasLoadedOnce = true
            loadState = .loaded
            logger.info("loadFromDisk OK userId=\(self.info?.userId ?? -1)")
        }
    }

    private func saveToDisk() {
        let snap = CachedSnapshot(
            info: info, mine: mine,
            followingCount: followingCount,
            followersCount: followersCount,
            friendsCount: friendsCount
        )
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    // MARK: - Helpers

    /// ISO 两字母国家码 → Unicode regional indicator emoji。非法回落 🌐。
    static func flagEmoji(from countryCode: String) -> String {
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
