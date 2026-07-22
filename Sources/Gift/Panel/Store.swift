import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "GiftPanel.Store")

/// 公共礼物面板 store（spec §2.1）—— 状态机 + config-driven 分派 + 数据源调用。
///
/// 生命周期：sheet present → `@StateObject` init → task load() → 用户交互 → dismiss → 销毁。
///
/// **H-5 扩展**：Phase 加 `.insufficientBalance`（本地校验 or 后端 code 1019）；
/// `.send` case 支持注入真 `PartyGiftSendService`（`FooterMode.send` 关联值扩 optional service）；
/// balance 拉取从 `load()` 剥离到独立 `refreshBalance()`（spec F1 · balance 独立不阻塞 loaded）。
///
/// 7 态：`initial → loading → loaded ↔ sending → sent`（sendFailed / insufficientBalance / loadFailed 分支）。
@MainActor
final class CommonGiftPanelStore: ObservableObject {

    // MARK: - Phase

    enum Phase: Equatable {
        case initial
        case loading
        case loaded
        case loadFailed(String)
        case sending
        case sent
        case sendFailed(String)
        /// 余额不足（本地校验命中 or 后端 code 1019 返回）—— UI 底部按钮切 "Recharge"（H-5）
        case insufficientBalance
    }

    // MARK: - Published state

    @Published private(set) var phase: Phase = .initial
    @Published private(set) var currentTab: GiftPanelTab
    @Published private(set) var selectedId: Int64?
    @Published private(set) var count: Int = 1
    @Published private(set) var receiversSelection: Set<String>
    @Published private(set) var balanceValue: Int64?
    /// refreshBalance 进行中标志（用户 tap 余额胶囊时右侧显示转圈；对齐 Footer.balanceView UX）
    @Published private(set) var isRefreshingBalance: Bool = false
    /// dismiss 时判定"是否已完成用户 action"（instantSelect / confirm 后 / send sent 后）→ true 则 onDismiss 不触发
    private(set) var didCompleteAction: Bool = false

    // MARK: - Deps

    let config: CommonGiftPanelConfig
    private var groups: [GiftPanelTab: [GiftListData]] = [:]

    // MARK: - Init

    init(config: CommonGiftPanelConfig) {
        self.config = config
        self.currentTab = config.resolvedInitialTab
        self.receiversSelection = config.receivers?.initialSelection ?? []
        if let init0 = config.initialSelection {
            self.selectedId = init0.id
        }
        // count 初始化按 stepper range 下界（stepper.hidden 时恒 1）
        if let r = config.countStepper.range {
            self.count = r.lowerBound
        }
    }

    // MARK: - Load

    func load() async {
        switch phase {
        case .initial, .loadFailed:
            break  // 允许 initial / loadFailed 触发；其他态忽略避免重复 load
        default:
            return
        }
        // Fast path（跳过 loading 转圈）：同步查 dataSource 缓存 —— 命中直接切 loaded 展示 grid，
        // 避免每次开面板都短暂 render ProgressView 帧。cache 未命中才走原 async loading path。
        // balance 同步 seed（review #2）：syncCachedBalance 从 dataSource 内部 `_latestBalance` 拿；
        //   避免 phase=.loaded 后 balanceValue nil 让 canTriggerAction balance gate 短暂失效（几十 ms
        //   内用户 tap Send 被"允许"，实际走后端 1019 兜底 → 削弱 fast-path 秒开体验）。
        //   之后 refreshBalance 异步补齐（若 dataSource 内 balance 与真实有 lag）。
        if let cached = config.dataSource.syncCachedGroups() {
            var map: [GiftPanelTab: [GiftListData]] = [:]
            for g in cached { map[g.tab] = g.gifts }
            self.groups = map
            if let syncedBalance = config.balance.source?.syncCachedBalance() {
                self.balanceValue = syncedBalance
            }
            self.phase = .loaded
            enforceSelectionInvariant()
            await refreshBalance()
            return
        }
        phase = .loading
        do {
            let all = try await config.dataSource.loadGifts()
            var map: [GiftPanelTab: [GiftListData]] = [:]
            for g in all { map[g.tab] = g.gifts }
            self.groups = map
            self.phase = .loaded
            // initialSelection 若被 minPrice 过滤 → 静默 clear（spec §5.2 R11）
            enforceSelectionInvariant()
        } catch let e as APIError {
            logger.error("loadGifts APIError code=\(e.code, privacy: .public) msg=\(e.message, privacy: .private)")
            phase = .loadFailed(e.message)
            return
        } catch {
            logger.error("loadGifts error: \(String(describing: error), privacy: .private)")
            phase = .loadFailed(error.localizedDescription)
            return
        }
        // H-5 spec F1 · P2-12：balance 独立不阻塞 loaded — gift list 完成后并行拉一次 balance
        // balance 失败不影响 phase = .loaded（余额显 `--`）
        await refreshBalance()
    }

    /// 拉取余额并更新 `balanceValue`（独立于 gift list 加载 · spec F1 修订）。
    ///
    /// 场景：
    /// - `load()` 内 gift list 成功后调
    /// - `.send` case 网络失败但服务端可能已扣款 → 关面板重开时兜底重拉
    /// - insufficientBalance 态用户完成充值后手动 refresh（本轮不做真充值页；下版本挂钩）
    func refreshBalance() async {
        guard let source = config.balance.source else { return }
        // 标记进行中 → Footer.balanceView 右侧 ProgressView 显示；defer 兜底完成/取消都置 false
        isRefreshingBalance = true
        defer { isRefreshingBalance = false }
        // 走真网络（refreshFromServer default 回退 currentBalance；派对房 override 调 API 拿最新 userDiamond）
        // 之前只调 currentBalance() 返内部缓存 → 用户看不到实际变化 + 转圈瞬间闪过；改真拉才有 UX 反馈
        self.balanceValue = await source.refreshFromServer()
    }

    // MARK: - Grid select / tab

    func selectGift(_ id: Int64) {
        guard config.interaction == .selectable else { return }
        guard !isBusy else { return }
        if selectedId == id {
            selectedId = nil
        } else {
            selectedId = id
        }
    }

    /// IM 场景 tap cell 立即触发（footer = .instantSelect）—— spec §1.4。
    func triggerInstantSelect(_ gift: GiftListData) {
        guard case .instantSelect(let onSelect) = config.footer else { return }
        guard !isBusy else { return }
        selectedId = gift.id
        didCompleteAction = true
        phase = .sent
        onSelect(gift)
    }

    func switchTab(_ tab: GiftPanelTab) {
        guard config.tabs.contains(tab), tab != currentTab else { return }
        guard !isBusy else { return }
        currentTab = tab
        // selectedId 若不在新 tab → clear（spec §2.4 不变量 + R4）
        enforceSelectionInvariant()
    }

    // MARK: - Count stepper

    func setCount(_ n: Int) {
        guard let r = config.countStepper.range else { return }
        count = min(max(n, r.lowerBound), r.upperBound)
    }

    func incrementCount() {
        guard let r = config.countStepper.range else { return }
        if count < r.upperBound { count += 1 }
    }

    func decrementCount() {
        guard let r = config.countStepper.range else { return }
        if count > r.lowerBound { count -= 1 }
    }

    // MARK: - Receivers

    func toggleReceiver(_ id: String) {
        guard let cfg = config.receivers else { return }
        if cfg.allowMultiSelect {
            if receiversSelection.contains(id) {
                receiversSelection.remove(id)
            } else {
                receiversSelection.insert(id)
            }
        } else {
            // 单选：tap 已选 → 清空；否则唯一选中
            if receiversSelection.contains(id) {
                receiversSelection.removeAll()
            } else {
                receiversSelection = [id]
            }
        }
    }

    /// All 按钮：全选/全反选（allowMulti=true 且 showAllButton=true）
    func toggleAllReceivers() {
        guard let cfg = config.receivers, cfg.allowMultiSelect, cfg.showAllButton else { return }
        let allIds = Set(cfg.items.map(\.id))
        if receiversSelection == allIds {
            receiversSelection.removeAll()
        } else {
            receiversSelection = allIds
        }
    }

    // MARK: - Trigger action / backpack

    /// 主按钮点击（footer=.confirm/.send/.askFor）；.none/.instantSelect 不渲染按钮不触发。
    ///
    /// **H-5 phase 分流**：
    /// - `phase = .insufficientBalance` → 调 config.onRechargeRequested + 主动重拉 balance；若够了切 loaded
    /// - `phase = .sendFailed` → canTriggerAction 允许（isBusy=false），走正常 .send 分支重发（保留 selection）
    /// - 其他态 → canTriggerAction gate 后走正常分派
    func triggerAction() {
        // H-5 F11 · phase = insufficientBalance 时 tap "Recharge" 按钮：
        // 1) 通知 caller（挂 toast "充值功能开发中"）；
        // 2) 主动重拉一次 balance——若用户完成充值 balance 会更新，重算后切回 .loaded
        if phase == .insufficientBalance {
            config.onRechargeRequested?()
            Task { [weak self] in
                await self?.refreshBalance()
                guard let self else { return }
                if let g = self.currentSelectedGift, let bal = self.balanceValue {
                    // 对齐 H5 priceTotal 公式：giftPrice × count × 受者数
                    let need = g.giftPrice * Int64(self.count) * Int64(self.totalReceiverMultiplier)
                    if bal >= need { self.phase = .loaded }
                }
            }
            return
        }
        guard canTriggerAction else { return }
        switch config.footer {
        case .none, .instantSelect:
            return  // 不应发生（按钮不渲染）
        case .confirm(_, let onConfirm):
            let g = currentSelectedGift  // 可能 nil（"移除"语义）
            didCompleteAction = true
            phase = .sent
            onConfirm(g, count)
        case .send(let onSend, let service):
            guard let g = currentSelectedGift else { return }
            let accids = Array(receiversSelection)
            // H-5 分流：service 非 nil → 真 sendGift；否则回退 300ms mock（历史 pattern 保底）
            Task { [weak self] in
                await self?.performSend(gift: g, accids: accids, onSend: onSend, service: service)
            }
        case .askFor(let onAsk):
            guard let g = currentSelectedGift else { return }
            didCompleteAction = true
            phase = .sent
            onAsk(g)
        }
    }

    /// 真 send 内部实作（`triggerAction()` case `.send` 分流入口）。
    ///
    /// - service 非 nil：走真 `PartyGiftSendService.send` + phase 分流
    ///   - 成功 → phase.sent · balanceValue 从 result.userDiamond 更新（若非 nil）· onSend callback
    ///   - `PartyAPIError.business(code: "1019", ...)` 或 `APIError code == "1019"` → phase.insufficientBalance（spec R4 精确判定）
    ///   - 其他错误 → phase.sendFailed(msg)
    /// - service = nil：300ms mock 保 backward compat（历史 spec 骨架路径）
    private func performSend(gift: GiftListData,
                             accids: [String],
                             onSend: @escaping (GiftListData, Int, [String]) -> Void,
                             service: PartyGiftSendService?) async {
        self.phase = .sending
        if let service {
            do {
                let result = try await service.send(
                    giftId: gift.id,
                    num: self.count,
                    yxAccidList: accids
                )
                // 余额更新（若 response 携带；nil 时保留 UI 现值等待下次 refreshBalance 兜底）
                if let newBalance = result.userDiamond {
                    self.balanceValue = newBalance
                    // sync 到 PartyGiftDataSource 内部 balance cache + GiftCatalogCache（下次开面板显示最新）
                    // 类型转换而非 protocol 扩展：BalanceSource protocol 无需暴露 update 方法给通用场景
                    // #if !HILY_TESTS：PartyGiftDataSource 依赖 PartyAPI 不入 tests 白名单
                    #if !HILY_TESTS
                    if let partySource = config.dataSource as? PartyGiftDataSource {
                        partySource.updateBalanceFromSend(newBalance)
                    }
                    #endif
                }
                self.didCompleteAction = true
                self.phase = .sent
                onSend(gift, self.count, accids)
            } catch let e as GiftSendError {
                switch e {
                case .insufficientBalance:
                    logger.info("sendGift insufficient balance")
                    self.phase = .insufficientBalance
                case .generic(let msg):
                    logger.error("sendGift generic error: \(msg, privacy: .private)")
                    self.phase = .sendFailed(msg)
                }
            } catch {
                logger.error("sendGift unknown error: \(String(describing: error), privacy: .private)")
                self.phase = .sendFailed(error.localizedDescription)
            }
        } else {
            // 历史 mock 路径（factory 未注入 service 时兜底）
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.didCompleteAction = true
            self.phase = .sent
            onSend(gift, self.count, accids)
        }
    }

    /// Backpack icon tap（config.backpack=.visible 时才渲染 icon）
    func triggerBackpack() {
        config.backpack.onTap?()
    }

    // MARK: - Computed

    /// 当前 tab 过滤后可见列表（+ minPrice/maxPrice）
    var visibleGifts: [GiftListData] {
        gifts(for: currentTab)
    }

    /// 指定 tab 的过滤后列表（TabView(.page) 每 page 独立渲染时用；对齐 H5 newGiftsPopup v-swiper 每 slot 独立数据）
    func gifts(for tab: GiftPanelTab) -> [GiftListData] {
        let raw = groups[tab] ?? []
        return raw.filter { g in
            if let lo = config.minPrice, g.giftPrice < lo { return false }
            if let hi = config.maxPrice, g.giftPrice > hi { return false }
            return true
        }
    }

    /// 是否可点主按钮（spec §1.4 canTriggerAction 公式）
    var canTriggerAction: Bool {
        guard !isBusy else { return false }
        switch config.footer {
        case .none, .instantSelect:
            return false
        case .confirm:
            // callGate 允许 nil = "移除"，只要 selection 状态合法即可点（selectedId != nil 或 selectedId == nil）
            // 但 wishGift 场景永远需要 selection，交由 factory 层内部 unwrap 保护——本层统一要求有 selection
            return selectedId != nil
        case .send:
            guard selectedId != nil else { return false }
            // receivers 传入 → 必须有选中受者
            if config.receivers != nil && receiversSelection.isEmpty { return false }
            // 余额若接入且不足 → 禁点（H+ 派对房实测；本轮 balanceValue 恒 nil 时不生效）
            // 对齐 H5 priceTotal 公式（party-gift-popup.vue L405）：giftPrice × count × 受者数
            //   config.receivers 未配置时按 1 计（无 receivers 场景保持向后兼容）
            if let g = currentSelectedGift, let bal = balanceValue {
                let need = g.giftPrice * Int64(count) * Int64(totalReceiverMultiplier)
                if bal < need { return false }
            }
            return true
        case .askFor:
            return selectedId != nil
        }
    }

    /// 当前受者乘数（对齐 H5 priceTotal = giftPrice × count × selectedCount）
    /// - 无 receivers config（wishGift/callGate/liveDisplayOnly 等）→ 1
    /// - 有 receivers config 但 selection 空 → 1（canTriggerAction 会 gate；此 fallback 防 0 需求）
    /// - 有 receivers config + selection 非空 → selection.count
    var totalReceiverMultiplier: Int {
        guard config.receivers != nil else { return 1 }
        return max(1, receiversSelection.count)
    }

    /// 当前选中的 gift（若 selectedId 有效）
    var currentSelectedGift: GiftListData? {
        guard let id = selectedId else { return nil }
        return visibleGifts.first { $0.id == id }
    }

    /// 状态机 busy：sending 期间锁 tap / stepper / tab
    var isBusy: Bool {
        phase == .sending
    }

    // MARK: - Testing hooks (HilyTests)

    #if DEBUG
    /// 单测友好：注入已加载的 groups + 直接置 loaded 态
    func _testInjectLoaded(_ all: [GiftPanelGroup]) {
        var map: [GiftPanelTab: [GiftListData]] = [:]
        for g in all { map[g.tab] = g.gifts }
        self.groups = map
        self.phase = .loaded
        enforceSelectionInvariant()
    }
    #endif

    // MARK: - Private

    /// 不变量执行：selectedId 若不在 visibleGifts → clear（可发生于 initialSelection 被过滤 / tab 切换）
    private func enforceSelectionInvariant() {
        guard let id = selectedId else { return }
        if !visibleGifts.contains(where: { $0.id == id }) {
            selectedId = nil
        }
    }
}
