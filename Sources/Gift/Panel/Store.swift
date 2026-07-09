import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "GiftPanel.Store")

/// 公共礼物面板 store（spec §2.1）—— 状态机 + config-driven 分派 + 数据源调用。
///
/// 生命周期：sheet present → `@StateObject` init → task load() → 用户交互 → dismiss → 销毁。
///
/// 6 态：`initial → loading → loaded ↔ sending → sent → dismissed`（sendFailed 分支保留但本轮 mock 不触发）。
@MainActor
public final class CommonGiftPanelStore: ObservableObject {

    // MARK: - Phase

    public enum Phase: Equatable {
        case initial
        case loading
        case loaded
        case loadFailed(String)
        case sending
        case sent
        case sendFailed(String)
    }

    // MARK: - Published state

    @Published public private(set) var phase: Phase = .initial
    @Published public private(set) var currentTab: GiftPanelTab
    @Published public private(set) var selectedId: Int64?
    @Published public private(set) var count: Int = 1
    @Published public private(set) var receiversSelection: Set<String>
    @Published public private(set) var balanceValue: Int64?
    /// dismiss 时判定"是否已完成用户 action"（instantSelect / confirm 后 / send sent 后）→ true 则 onDismiss 不触发
    public private(set) var didCompleteAction: Bool = false

    // MARK: - Deps

    public let config: CommonGiftPanelConfig
    private var groups: [GiftPanelTab: [GiftListData]] = [:]

    // MARK: - Init

    public init(config: CommonGiftPanelConfig) {
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

    public func load() async {
        switch phase {
        case .initial, .loadFailed:
            break  // 允许 initial / loadFailed 触发；其他态忽略避免重复 load
        default:
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
            // balance 拉一次（若 source 提供）
            if let source = config.balance.source {
                self.balanceValue = await source.currentBalance()
            }
        } catch let e as APIError {
            logger.error("loadGifts APIError code=\(e.code, privacy: .public) msg=\(e.message, privacy: .private)")
            phase = .loadFailed(e.message)
        } catch {
            logger.error("loadGifts error: \(String(describing: error), privacy: .private)")
            phase = .loadFailed(error.localizedDescription)
        }
    }

    // MARK: - Grid select / tab

    public func selectGift(_ id: Int64) {
        guard config.interaction == .selectable else { return }
        guard !isBusy else { return }
        if selectedId == id {
            selectedId = nil
        } else {
            selectedId = id
        }
    }

    /// IM 场景 tap cell 立即触发（footer = .instantSelect）—— spec §1.4。
    public func triggerInstantSelect(_ gift: GiftListData) {
        guard case .instantSelect(let onSelect) = config.footer else { return }
        guard !isBusy else { return }
        selectedId = gift.id
        didCompleteAction = true
        phase = .sent
        onSelect(gift)
    }

    public func switchTab(_ tab: GiftPanelTab) {
        guard config.tabs.contains(tab), tab != currentTab else { return }
        guard !isBusy else { return }
        currentTab = tab
        // selectedId 若不在新 tab → clear（spec §2.4 不变量 + R4）
        enforceSelectionInvariant()
    }

    // MARK: - Count stepper

    public func setCount(_ n: Int) {
        guard let r = config.countStepper.range else { return }
        count = min(max(n, r.lowerBound), r.upperBound)
    }

    public func incrementCount() {
        guard let r = config.countStepper.range else { return }
        if count < r.upperBound { count += 1 }
    }

    public func decrementCount() {
        guard let r = config.countStepper.range else { return }
        if count > r.lowerBound { count -= 1 }
    }

    // MARK: - Receivers

    public func toggleReceiver(_ id: String) {
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
    public func toggleAllReceivers() {
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
    public func triggerAction() {
        guard canTriggerAction else { return }
        switch config.footer {
        case .none, .instantSelect:
            return  // 不应发生（按钮不渲染）
        case .confirm(_, let onConfirm):
            let g = currentSelectedGift  // 可能 nil（"移除"语义）
            didCompleteAction = true
            phase = .sent
            onConfirm(g, count)
        case .send(let onSend):
            guard let g = currentSelectedGift else { return }
            let accids = Array(receiversSelection)
            // 本轮骨架：进入 sending → 300ms mock → sent + callback（H+ 接 sendGift 时替换）
            Task { [weak self] in
                self?.phase = .sending
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self else { return }
                self.didCompleteAction = true
                self.phase = .sent
                onSend(g, self.count, accids)
            }
        case .askFor(let onAsk):
            guard let g = currentSelectedGift else { return }
            didCompleteAction = true
            phase = .sent
            onAsk(g)
        }
    }

    /// Backpack icon tap（config.backpack=.visible 时才渲染 icon）
    public func triggerBackpack() {
        config.backpack.onTap?()
    }

    // MARK: - Computed

    /// 当前 tab 过滤后可见列表（+ minPrice/maxPrice）
    public var visibleGifts: [GiftListData] {
        gifts(for: currentTab)
    }

    /// 指定 tab 的过滤后列表（TabView(.page) 每 page 独立渲染时用；对齐 H5 newGiftsPopup v-swiper 每 slot 独立数据）
    public func gifts(for tab: GiftPanelTab) -> [GiftListData] {
        let raw = groups[tab] ?? []
        return raw.filter { g in
            if let lo = config.minPrice, g.giftPrice < lo { return false }
            if let hi = config.maxPrice, g.giftPrice > hi { return false }
            return true
        }
    }

    /// 是否可点主按钮（spec §1.4 canTriggerAction 公式）
    public var canTriggerAction: Bool {
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
            if let g = currentSelectedGift, let bal = balanceValue {
                let need = g.giftPrice * Int64(count)
                if bal < need { return false }
            }
            return true
        case .askFor:
            return selectedId != nil
        }
    }

    /// 当前选中的 gift（若 selectedId 有效）
    public var currentSelectedGift: GiftListData? {
        guard let id = selectedId else { return nil }
        return visibleGifts.first { $0.id == id }
    }

    /// 状态机 busy：sending 期间锁 tap / stepper / tab
    public var isBusy: Bool {
        phase == .sending
    }

    // MARK: - Testing hooks (HilyTests)

    #if DEBUG
    /// 单测友好：注入已加载的 groups + 直接置 loaded 态
    public func _testInjectLoaded(_ all: [GiftPanelGroup]) {
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
