import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "WishSettingSharedStore")

/// LiveSettings ↔ WishSetting 跨页中转 + App 重启保留（对齐 H5 `wishStore` pinia persist paths：
/// `wishlist / promiseType / promiseTemplateId / promiseText / ruleChecked`）。
///
/// **单例合理性**：H5 用 pinia store 在两页间共享 state；iOS 侧同样需要跨 View 生命周期的共享——
/// `LiveSettingsView` push 到 `WishSettingView`，用户 Save 回到 LiveSettings 后，wishlistCard 预览要读到最新配置；
/// 且开播时 `LiveSettingsStore.startTapped()` 需要读取组装到 `beginLiveRoom` payload。
@MainActor
final class WishSettingSharedStore: ObservableObject {
    static let shared = WishSettingSharedStore()

    @Published var wishlist: [WishGift] = []
    @Published var promiseType: PromiseType = .none
    @Published var promiseTemplateId: Int64 = 0
    @Published var promiseText: String = ""
    @Published var ruleChecked: Bool = false

    // MARK: - App 级 cache（stage 2 优化：跨 view 重建保留，避免 view 每次 push 都拉后端）
    //
    // 触发根因：`WishSettingView` 用 `@StateObject var store = WishSettingStore()`——view 生命周期绑定，
    // 每次 push 都新建 store → `commonTemplates` 空 → `.task { store.load() }` 又拉一次。
    // in-flight guard 也在本层做，避免 load() / changeType() / dropdown 三处并发首次拉。
    @Published private(set) var commonTemplates: [WishTemplate] = []
    @Published private(set) var privateTemplates: [WishTemplate] = []
    @Published private(set) var wishGiftMaxNum: Int = 3
    @Published private(set) var loadingCommonTemplates: Bool = false
    @Published private(set) var loadingPrivateTemplates: Bool = false
    // didLoad 标志：**空数组也算成功拉过**，不重复请求。修复 stage 2 遗漏的空态 cache 失效
    private var didLoadCommon: Bool = false
    private var didLoadPrivate: Bool = false
    private var didLoadWishGiftMaxNum: Bool = false

    private let key = "wishSetting.state.v1"

    private init() {
        load()
    }

    // MARK: - Ensure fetch（幂等 + in-flight guard；App 生命周期内至多 1 次成功拉）

    /// 若已成功拉过（含空数组）或当前在飞，跳过。**成功后 didLoadCommon=true**，永不重拉。
    /// 失败保持 didLoadCommon=false，下次 tap 可重试。
    func ensureCommonTemplates() async {
        guard !loadingCommonTemplates, !didLoadCommon else { return }
        loadingCommonTemplates = true
        defer { loadingCommonTemplates = false }
        do {
            commonTemplates = try await WishSettingService.getTemplateList()
            didLoadCommon = true
            logger.info("ensureCommonTemplates ok count=\(self.commonTemplates.count)")
        } catch {
            logger.warning("ensureCommonTemplates failed: \(String(describing: error))")
        }
    }

    /// 同 `ensureCommonTemplates`：**didLoadPrivate 标志区分"没拉过" vs "拉过是空"**
    /// —— 后端返回空数组时也算成功，不重拉；避免空态 cache 失效导致每次切 Private chip 都重复请求
    func ensurePrivateTemplates() async {
        guard !loadingPrivateTemplates, !didLoadPrivate else { return }
        loadingPrivateTemplates = true
        defer { loadingPrivateTemplates = false }
        do {
            privateTemplates = try await WishSettingService.getPromisePool()
            didLoadPrivate = true
            logger.info("ensurePrivateTemplates ok count=\(self.privateTemplates.count)")
        } catch {
            logger.warning("ensurePrivateTemplates failed: \(String(describing: error))")
        }
    }

    /// wishGiftMaxNum 后端配置项，App 生命周期内至多拉 1 次。失败保留默认 3 + 不阻塞下次重试
    func ensureWishGiftMaxNum() async {
        guard !didLoadWishGiftMaxNum else { return }
        do {
            wishGiftMaxNum = try await WishSettingService.getWishGiftMaxNum()
            didLoadWishGiftMaxNum = true
            logger.info("ensureWishGiftMaxNum ok = \(self.wishGiftMaxNum)")
        } catch {
            // 保留默认 3，允许下次重试
            logger.warning("ensureWishGiftMaxNum failed: \(String(describing: error))")
        }
    }

    /// 供 Store 层 delete 私人 template 后同步 cache（stage 1 stub 本地删；stage 3 补 DELETE 接入后仍需此方法）
    func removeFromPrivateTemplates(id: Int64) {
        privateTemplates.removeAll { $0.id == id }
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        let wishlist: [WishGift]
        let promiseType: Int
        let promiseTemplateId: Int64
        let promiseText: String
        let ruleChecked: Bool
    }

    /// 由 WishSettingStore.save() 调用；成功持久化 → 通知观察方（LiveSettings.wishlistCard 预览刷新）
    func commit(wishlist: [WishGift],
                promiseType: PromiseType,
                promiseTemplateId: Int64,
                promiseText: String,
                ruleChecked: Bool) {
        // 序列化前重赋 sortWeight = index（对齐 H5 index.vue:220）
        let reweighted = wishlist.enumerated().map { (idx, g) -> WishGift in
            var copy = g
            copy.sortWeight = idx
            return copy
        }
        self.wishlist = reweighted
        self.promiseType = promiseType
        self.promiseTemplateId = promiseTemplateId
        self.promiseText = promiseText
        self.ruleChecked = ruleChecked
        persist()
    }

    /// 清空（对齐 H5 wishStore.reset）
    /// P1-1 加固：账号切换（logout → 新登录）语义 —— 除持久化字段外，也清 App 级 template cache
    /// + didLoad 标志，避免上个账号的 privateTemplates / commonTemplates 遗留到新账号
    func reset() {
        wishlist = []
        promiseType = .none
        promiseTemplateId = 0
        promiseText = ""
        ruleChecked = false
        commonTemplates = []
        privateTemplates = []
        wishGiftMaxNum = 3
        didLoadCommon = false
        didLoadPrivate = false
        didLoadWishGiftMaxNum = false
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func persist() {
        let snap = Snapshot(
            wishlist: wishlist,
            promiseType: promiseType.rawValue,
            promiseTemplateId: promiseTemplateId,
            promiseText: promiseText,
            ruleChecked: ruleChecked
        )
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            logger.error("persist encode failed")
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        self.wishlist = snap.wishlist
        self.promiseType = PromiseType(rawValue: snap.promiseType) ?? .none
        self.promiseTemplateId = snap.promiseTemplateId
        self.promiseText = snap.promiseText
        self.ruleChecked = snap.ruleChecked
    }
}
