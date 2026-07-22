import Combine
import Foundation
import os

/// WishSetting 页 Store（L-spec §2.2）。
///
/// 承载：3 档 promiseType 切换 / 模板 dropdown 数据 / wishlist 礼物 3-上限操作 / wishTheme 独立提交审核 /
/// ruleChecked 勾选 / Save 组合校验 + 持久化到 SharedStore。
///
/// 审核成功、承诺规范和审核记录均沿用 H5 的实际入口与数据流。
@MainActor
final class WishSettingStore: ObservableObject {

    // MARK: - Published
    @Published private(set) var state: WishSettingState = .loading
    @Published var wishlist: [WishGift] = []
    @Published var promiseType: PromiseType = .none
    @Published var promiseTemplateId: Int64 = 0
    @Published var promiseText: String = ""
    @Published var wishTheme: String = ""
    @Published var ruleChecked: Bool = false
    @Published var showSubmitSuccessAlert: Bool = false
    @Published private(set) var isSubmittingSave: Bool = false

    /// P1-2：toast（对齐 H5 `showToast`）—— 20004 承诺审核中 / 其它可修正边界用 toast，
    /// 与 `state=.error` 语义区分（后者是接口/系统错误的 error banner）
    @Published var toastMessage: String?
    private var toastClearTask: Task<Void, Never>?

    // MARK: - 从 SharedStore 转发（stage 2 优化：cache 上抬到 App 级 SharedStore，view 重建不再重复拉）
    //
    // 这些数据全 App 生命周期内只应拉 1 次（templates 后端配置项，几乎不变）——
    // 见 `WishSettingSharedStore.ensureCommonTemplates` / `ensureWishGiftMaxNum` 的 in-flight guard
    // + `commonTemplates.isEmpty` 幂等 guard。
    //
    // 用 computed property 转发；`bindSharedForwarding()` 订阅 shared.objectWillChange
    // 转发到 self.objectWillChange，让 SwiftUI View 通过 @StateObject/@ObservedObject 感知变化。
    var wishGiftMaxNum: Int { WishSettingSharedStore.shared.wishGiftMaxNum }
    var commonTemplates: [WishTemplate] { WishSettingSharedStore.shared.commonTemplates }
    var privateTemplates: [WishTemplate] { WishSettingSharedStore.shared.privateTemplates }
    var loadingTemplates: Bool { WishSettingSharedStore.shared.loadingCommonTemplates }
    var loadingPrivate: Bool { WishSettingSharedStore.shared.loadingPrivateTemplates }

    private var cancellables: Set<AnyCancellable> = []
    private let logger = Logger(subsystem: "com.anchor.livechat", category: "WishSettingStore")

    /// H5 `wishlist-free-text.vue` / `wishSetting/index.vue` 的真实限制。
    static let themeMaxLen: Int = 15

    // MARK: - Derived

    /// Save 按钮亮起条件（对齐 H5 index.vue:69-80）
    var canSave: Bool {
        guard ruleChecked, !wishlist.isEmpty else { return false }
        if promiseType == .common && promiseTemplateId == 0 { return false }
        if promiseType == .private_ && promiseText.isEmpty { return false }
        return true
    }

    var canAddMoreGift: Bool { wishlist.count < wishGiftMaxNum }

    // MARK: - Lifecycle

    init() {
        // 从 SharedStore 初始化（App 重启或从 LiveSettings 再次进入本页时保留状态）
        let shared = WishSettingSharedStore.shared
        self.wishlist = shared.wishlist
        self.promiseType = shared.promiseType
        self.promiseTemplateId = shared.promiseTemplateId
        self.promiseText = shared.promiseText
        self.wishTheme = shared.wishTheme
        self.ruleChecked = shared.ruleChecked
        bindSharedForwarding()
    }

    /// 订阅 SharedStore 变化转发到本 store 的 objectWillChange，让 view 感知 cache 更新
    /// （templates 拉完 / wishGiftMaxNum 刷新时 view 自动 rerender）。
    /// [weak self] 防循环引用；WishSettingSharedStore 是 shared 单例不会释放，本 store 是 view 生命周期。
    private func bindSharedForwarding() {
        WishSettingSharedStore.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// onAppear 调用：确保 wishGiftMaxNum + 若 promiseType 已 selected 则确保对应 dropdown 数据。
    /// **stage 2 优化**：全部委托 SharedStore `ensure*` 幂等 API，App 生命周期内每种数据至多真实拉一次。
    func load() async {
        state = .loading
        await WishSettingSharedStore.shared.ensureWishGiftMaxNum()
        if promiseType == .common {
            await WishSettingSharedStore.shared.ensureCommonTemplates()
            // "补文案"逻辑：拉完模板后若 promiseTemplateId 有值但 promiseText 空（persist decode 边界），
            // 用模板 id 找回文案（对齐旧实现 line 99-102，兼容 v1 存档）
            if promiseTemplateId != 0, promiseText.isEmpty,
               let tpl = commonTemplates.first(where: { $0.id == promiseTemplateId }) {
                promiseText = tpl.content
            }
        } else if promiseType == .private_ {
            await WishSettingSharedStore.shared.ensurePrivateTemplates()
        }
        state = .editing
    }

    // MARK: - Type 切换 + Templates

    func changeType(_ type: PromiseType) async {
        if case .error = state { state = .editing }
        promiseType = type
        // 切类型清空选中文案（避免 A 选的串到 B，对齐 H5 index.vue:143-145）
        promiseText = ""
        promiseTemplateId = 0
        if type == .common {
            await WishSettingSharedStore.shared.ensureCommonTemplates()
        } else if type == .private_ {
            await WishSettingSharedStore.shared.ensurePrivateTemplates()
        }
    }

    /// 提供给 View 的 dropdown 展开按钮：委托 SharedStore ensure（幂等）
    func fetchCommonTemplates() async {
        await WishSettingSharedStore.shared.ensureCommonTemplates()
    }

    func fetchPrivateTemplates() async {
        await WishSettingSharedStore.shared.ensurePrivateTemplates()
    }

    /// 对齐 H5 `toggleDropdown`：模板尚在请求时先等待；池为空时只提示，不展开一个空列表。
    func shouldOpenTemplateDropdown(currentlyOpen: Bool) async -> Bool {
        guard promiseType != .none else { return false }
        guard !currentlyOpen else { return false }

        switch promiseType {
        case .common:
            if !loadingTemplates {
                await fetchCommonTemplates()
            }
            while loadingTemplates, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled, !commonTemplates.isEmpty else {
                if !Task.isCancelled { showToast(L10n.wishSettingNoTemplateAvailable) }
                return false
            }
        case .private_:
            if !loadingPrivate {
                await fetchPrivateTemplates()
            }
            while loadingPrivate, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled, !privateTemplates.isEmpty else {
                if !Task.isCancelled { showToast(L10n.wishSettingNoTemplateAvailable) }
                return false
            }
        case .none:
            return false
        }
        return true
    }

    func pickCommonTemplate(_ tpl: WishTemplate) {
        if case .error = state { state = .editing }
        promiseTemplateId = tpl.id
        promiseText = tpl.content
    }

    func pickPrivateTemplate(_ tpl: WishTemplate) {
        if case .error = state { state = .editing }
        promiseTemplateId = tpl.id
        promiseText = tpl.content
    }

    /// 删除私人池条目（stage 1 stub：Service 不发接口；stage 2 优化：委托 SharedStore 同步 cache）
    func deletePrivateTemplate(_ tpl: WishTemplate) async {
        do {
            try await WishSettingService.deletePromisePoolItem(id: tpl.id)
            WishSettingSharedStore.shared.removeFromPrivateTemplates(id: tpl.id)
            if promiseTemplateId == tpl.id {
                promiseTemplateId = 0
                promiseText = ""
            }
        } catch {
            logger.warning("deletePrivateTemplate ignored (stub): \(String(describing: error))")
        }
    }

    // MARK: - Wish theme 独立提交

    /// tap 顶部 Wish theme Submit（对齐 H5 index.vue:238-274 `submitWishThemeForAudit`）
    /// **stage 2 修订**：字数上限 15 → 20（对齐设计稿"(0/20)"计数；H5 code 15 是老规则）
    func submitWishTheme() async {
        let trimmed = wishTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        // 可修正边界统一走 toast（对齐 H5 `showToast` + iOS 内 pattern 一致性）
        // P1-new-1 empty：UI submit 按钮已 disable 时不会触发；防御性保留
        guard !trimmed.isEmpty else {
            showToast(L10n.wishSettingPleaseEnterTheme)
            state = .editing
            return
        }
        // P1-new-2 > 20：TextField 无 maxLength，用户可输超长 → 真触发
        guard trimmed.count <= Self.themeMaxLen else {
            showToast(L10n.wishSettingThemeMaxLen)
            state = .editing
            return
        }
        guard state != .submittingTheme else { return }
        state = .submittingTheme
        do {
            try await WishSettingService.submitFreePromise(content: trimmed)
            wishTheme = ""
            state = .editing
            showSubmitSuccessAlert = true
        } catch let e as APIError {
            // 20004「承诺审核中」：走 toast 展示 backend message（对齐 H5 index.vue:268-269 `showToast`）
            // P1-2 修复：spec L §1.5 明确此码应用 toast 而非 error banner
            if e.code == "20004" {
                state = .editing
                showToast(e.message)
            } else {
                state = .error(String(format: L10n.livePrepareErrorPrefix, e.message, e.code))
            }
        } catch {
            state = .error(String(format: L10n.livePrepareErrorGeneric, error.localizedDescription))
        }
    }

    // MARK: - Wishlist 礼物操作

    /// 添加/累加（对齐 H5 index.vue:281-296）
    func addGift(_ gift: GiftListData, count: Int) {
        if case .error = state { state = .editing }
        let n = max(1, min(99, count))
        if let idx = wishlist.firstIndex(where: { $0.id == gift.id }) {
            wishlist[idx].giftNum = min(99, wishlist[idx].giftNum + n)
        } else {
            // P1-new-3 满 3：UI 层已 `if canAddMoreGift` 阻断 + 按钮；防御性保留 + 走 toast 保持 pattern 一致
            guard wishlist.count < wishGiftMaxNum else {
                showToast(String(format: L10n.wishSettingUpToFormat, wishGiftMaxNum))
                return
            }
            wishlist.append(WishGift(from: gift, giftNum: n, sortWeight: wishlist.count))
        }
    }

    /// ± 数量按钮（±1）
    func changeGiftNum(id: Int64, delta: Int) {
        guard let idx = wishlist.firstIndex(where: { $0.id == id }) else { return }
        let next = wishlist[idx].giftNum + delta
        if next < 1 { return }
        // P1-new-4 > 99：UI 层已 `.disabled(g.giftNum >= 99)` 阻断；防御性保留 + 走 toast 保持 pattern 一致
        if next > 99 {
            showToast(L10n.wishSettingMaxGiftNum)
            return
        }
        wishlist[idx].giftNum = next
    }

    func removeGift(id: Int64) {
        wishlist.removeAll { $0.id == id }
    }

    // MARK: - Save

    /// tap Save 按钮：canSave 通过 → 持久化到 SharedStore → View 层 pop 回
    /// 返回 true = 成功持久化（View 层 dismiss）
    func save() -> Bool {
        guard canSave else { return false }
        WishSettingSharedStore.shared.commit(
            wishlist: wishlist,
            promiseType: promiseType,
            promiseTemplateId: promiseTemplateId,
            promiseText: promiseText,
            wishTheme: wishTheme,
            ruleChecked: ruleChecked
        )
        logger.info("save ok wishlist=\(self.wishlist.count) promiseType=\(self.promiseType.rawValue)")
        return true
    }

    /// P0-1：Save 按钮 tap 入口（对齐 H5 `onSubmit` index.vue:351-397）
    /// Save 按钮改为**始终可点**；本方法按 canSave 4 项失败原因分层给具体 toast。
    /// 若 canSave 通过 → save() 持久化 → 触发 P1-2 "Saved" toast 后延迟 pop。
    /// 返回：`.saved` = View 层显 "Saved" toast + 延迟 pop；`.failed` = 已经 toast 具体错因，view 不 pop
    enum SubmitResult { case saved, failed }
    func submitTapped() async -> SubmitResult {
        // P0-1 分层校验（顺序对齐 H5 index.vue:352-360 不可改）
        if !ruleChecked {
            showToast(L10n.wishSettingPleaseAgreeRule)
            return .failed
        }
        if wishlist.isEmpty {
            showToast(L10n.wishSettingPleaseAddGift)
            return .failed
        }
        if promiseType == .common && promiseTemplateId == 0 {
            showToast(L10n.wishSettingPleasePickTemplate)
            return .failed
        }
        if promiseType == .private_ && promiseText.isEmpty {
            showToast(L10n.wishSettingPleasePickPrivate)
            return .failed
        }
        guard !isSubmittingSave else { return .failed }
        isSubmittingSave = true
        defer { isSubmittingSave = false }
        // 全过 → 持久化
        _ = save()  // canSave 已保证过；save 内的 guard 不会命中 return false
        // H5 `saveAndBack`：首次勾选规则后先提交同意回执；成功才写本地标记，
        // 失败仍保存配置，但下次开播会继续弹规则确认。
        if ruleChecked, !UserDefaults.standard.bool(forKey: "wishRuleAgreed") {
            do {
                try await LiveService.clickWishAgreement()
                UserDefaults.standard.set(true, forKey: "wishRuleAgreed")
            } catch {
                logger.warning("clickWishAgreement failed while saving wishlist: \(String(describing: error), privacy: .private)")
            }
        }
        // P1-2 saveAndBack 反馈（对齐 H5 index.vue:396-397 `showToast('Saved') + 600ms history.back()`）
        showToast(L10n.wishSettingSaved)
        return .saved
    }

    // MARK: - Error 自清

    func clearErrorIfNeeded() {
        if case .error = state { state = .editing }
    }

    // MARK: - Toast（P1-2）

    /// 显示 toast 2s 后自动清空。重复触发 cancel 前一个任务，避免闪烁/stale 覆盖。
    /// 与 `LiveSettingsStore.showToast` 同 pattern
    func showToast(_ msg: String) {
        toastMessage = msg
        toastClearTask?.cancel()
        toastClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.toastMessage = nil }
        }
    }
}
