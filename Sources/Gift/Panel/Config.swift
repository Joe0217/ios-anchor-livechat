import Foundation

// MARK: - Config

/// 公共礼物面板配置（spec §2.2）—— 由调用方注入的全部开关与数据源。
///
/// 场景差异**全部**通过 config 表达；View / Store 内不写场景专有分支（避免 flag 硬编码）。
/// 便利工厂见 `CommonGiftPanelConfig.callGate / wishGift / liveDisplayOnly / imBind / partySend / callAskFor`。
struct CommonGiftPanelConfig {
    var tabs: [GiftPanelTab]
    /// 初始 tab；nil = tabs.first；不合法（不在 tabs 里）降级 tabs.first
    var initialTab: GiftPanelTab?
    var footer: FooterMode
    var countStepper: CountStepperConfig
    var balance: BalancePolicy
    var backpack: BackpackEntryPolicy
    var receivers: ReceiversConfig?
    var minPrice: Int64?
    var maxPrice: Int64?
    var initialSelection: GiftListData?
    var interaction: InteractionMode
    /// sheet 顶部标题；nil = 无 title
    var title: String?
    var dataSource: GiftPanelDataSource
    /// ×/swipe-down dismiss 触发；IM 场景借这个走 onCancel
    var onDismiss: (() -> Void)?
    /// tap "Recharge" 按钮触发（phase = insufficientBalance 时 · H-5）；
    /// 主动重拉一次 balance；若仍不足 caller 可挂 toast/CTA
    var onRechargeRequested: (() -> Void)?

    init(tabs: [GiftPanelTab] = [.popular],
                initialTab: GiftPanelTab? = nil,
                footer: FooterMode,
                countStepper: CountStepperConfig = .hidden,
                balance: BalancePolicy = .hidden,
                backpack: BackpackEntryPolicy = .hidden,
                receivers: ReceiversConfig? = nil,
                minPrice: Int64? = nil,
                maxPrice: Int64? = nil,
                initialSelection: GiftListData? = nil,
                interaction: InteractionMode = .selectable,
                title: String? = nil,
                dataSource: GiftPanelDataSource,
                onDismiss: (() -> Void)? = nil,
                onRechargeRequested: (() -> Void)? = nil) {
        self.tabs = tabs
        self.initialTab = initialTab
        self.footer = footer
        self.countStepper = countStepper
        self.balance = balance
        self.backpack = backpack
        self.receivers = receivers
        self.minPrice = minPrice
        self.maxPrice = maxPrice
        self.initialSelection = initialSelection
        self.interaction = interaction
        self.title = title
        self.dataSource = dataSource
        self.onDismiss = onDismiss
        self.onRechargeRequested = onRechargeRequested
    }

    /// 校验后的 initialTab（不在 tabs 里 → 降 tabs.first；tabs 为空 → .popular）
    var resolvedInitialTab: GiftPanelTab {
        if let t = initialTab, tabs.contains(t) { return t }
        return tabs.first ?? .popular
    }
}

// MARK: - Enums

/// 底部动作条模式（spec §1.4）。
enum FooterMode {
    /// 无 footer 按钮（直播中纯展示）
    case none
    /// Confirm 按钮（开播设置/心愿单）；label 由调用方传；回调返回可选 gift + count（callGate 允许 nil = "移除选中"）
    case confirm(label: String, onConfirm: (GiftListData?, Int) -> Void)
    /// tap cell 即触发（IM 场景），不渲染主按钮
    case instantSelect(onSelect: (GiftListData) -> Void)
    /// 派对房送礼（H-5 接入 `PartyGiftSendService`）；service=nil 时回退 300ms mock（历史 pattern 保底）。
    /// Store 内部：真 service → 真调用 + phase 分流（sent/sendFailed/insufficientBalance）；mock → 直接 sent
    case send(onSend: (GiftListData, Int, [String]) -> Void, service: PartyGiftSendService?)
    /// H+ 1v1 索要礼物占位
    case askFor(onAsk: (GiftListData) -> Void)
}

/// grid tap 交互模式（spec §2.4 不变量）。
enum InteractionMode {
    /// 正常选中/反选
    case selectable
    /// tap cell no-op；selectedId 恒 nil（直播中纯展示，替换旧 displayOnly flag）
    case readonly
}

/// 数量 stepper（spec §2.4 range clamp）。
enum CountStepperConfig {
    case hidden
    case visible(range: ClosedRange<Int>)

    var isVisible: Bool { if case .visible = self { return true }; return false }
    var range: ClosedRange<Int>? { if case .visible(let r) = self { return r }; return nil }
}

/// 余额展示策略（spec §2.2）。
enum BalancePolicy {
    case hidden
    case visible(source: GiftPanelBalanceSource)

    var source: GiftPanelBalanceSource? {
        if case .visible(let s) = self { return s }
        return nil
    }
    var isVisible: Bool { if case .visible = self { return true }; return false }
}

/// Backpack 右上角入口策略。
enum BackpackEntryPolicy {
    case hidden
    case visible(onTap: () -> Void)

    var onTap: (() -> Void)? {
        if case .visible(let cb) = self { return cb }
        return nil
    }
    var isVisible: Bool { if case .visible = self { return true }; return false }
}

// MARK: - Receivers config

/// 派对房受者头像行配置（spec §2.2）。本轮 UI 完成、数据源由调用方注入 mock。
struct ReceiversConfig {
    var items: [ReceiverItem]
    var allowMultiSelect: Bool
    var initialSelection: Set<String>
    var showAllButton: Bool

    init(items: [ReceiverItem],
                allowMultiSelect: Bool = false,
                initialSelection: Set<String> = [],
                showAllButton: Bool = false) {
        self.items = items
        self.allowMultiSelect = allowMultiSelect
        self.initialSelection = initialSelection
        self.showAllButton = showAllButton
    }
}

/// 单个受者项（对齐派对房麦位模型；派对房外场景 seatIndex=nil）。
struct ReceiverItem: Identifiable, Equatable {
    /// yxAccid（IM 唯一 id）
    let id: String
    let avatarURL: URL?
    let seatIndex: Int?

    init(id: String, avatarURL: URL?, seatIndex: Int? = nil) {
        self.id = id
        self.avatarURL = avatarURL
        self.seatIndex = seatIndex
    }
}

// MARK: - Preset factories

#if !HILY_TESTS
extension CommonGiftPanelConfig {
    /// 开播设置私 call 门槛（对齐旧 GiftPickerSheet(minPrice:...)）
    ///
    /// - Parameter minPrice: 门槛下限，展示层过滤
    /// - Parameter initialSelection: 之前选过的 gift；被 minPrice 过滤时静默 clear（对齐 H5）
    /// - Parameter onConfirm: 确认回调；nil 表示用户 confirm 但无选中（"移除"语义，对齐旧行为）
    static func callGate(minPrice: Int64,
                         initialSelection: GiftListData?,
                         onConfirm: @escaping (GiftListData?) -> Void) -> Self {
        Self(
            tabs: [.popular],
            footer: .confirm(label: L10n.giftPickerConfirm, onConfirm: { gift, _ in onConfirm(gift) }),
            countStepper: .hidden,
            minPrice: minPrice,
            initialSelection: initialSelection,
            interaction: .selectable,
            title: L10n.giftPickerTitle,
            dataSource: DefaultGiftDataSource(scene: .call)
        )
    }

    /// 心愿单选礼物 + 数量（对齐旧 WishGiftPickerSheet）
    static func wishGift(onConfirm: @escaping (GiftListData, Int) -> Void) -> Self {
        Self(
            tabs: [.popular],
            footer: .confirm(label: L10n.giftPickerConfirm, onConfirm: { gift, count in
                // canTriggerAction 保证 gift 非 nil 时才触发；理论上不会走 nil 分支
                if let g = gift { onConfirm(g, count) }
            }),
            countStepper: .visible(range: 1...99),
            interaction: .selectable,
            title: L10n.giftPickerTitle,
            dataSource: DefaultGiftDataSource(scene: .live)
        )
    }

    /// 直播中纯展示（对齐 H5 `newGiftsPopup.vue` —— 3 tab 分类 + scene LIVE + 无 Confirm）
    ///
    /// H5 主播端直播中看到的是**用户送给自己的礼物列表**（纯展示），无选中/送出动作。
    /// tabs 与 H5 对齐：Popular / Exclusive / Lucky Gift；scene = `.live`（非 `.call`）。
    static var liveDisplayOnly: Self {
        Self(
            tabs: [.popular, .exclusiveGift, .luckyGift],
            footer: .none,
            countStepper: .hidden,
            interaction: .readonly,
            title: nil,  // 3 tab 场景 tab bar 已承担分类展示，无独立 title（对齐 H5）
            dataSource: DefaultGiftDataSource(scene: .live)
        )
    }

    /// IM 场景礼物绑定（tap cell 即触发 + dismiss，对齐旧 GiftMessagePickerSheet）
    /// 参数含 internal 类型（GiftMessageServiceProtocol / GiftMessageItem），显式 internal 突破外层 public extension 的默认继承
    internal static func imBind(service: GiftMessageServiceProtocol,
                                onSelect: @escaping (GiftMessageItem) -> Void,
                                onCancel: @escaping () -> Void) -> Self {
        let adapter = IMGiftDataSource(service: service)
        return Self(
            tabs: [.popular],
            footer: .instantSelect(onSelect: { [weak adapter] gift in
                // adapter 内查表反算 GiftMessageItem；查不到（理论上不可能，本次 load 的 id 必在表内）静默 drop
                if let item = adapter?.itemById(gift.id) {
                    onSelect(item)
                }
            }),
            countStepper: .hidden,
            interaction: .selectable,
            title: L10n.GiftMessage.giftPickerTitle,
            dataSource: adapter,
            onDismiss: onCancel
        )
    }

    /// 派对房送礼（H-5 接入 · spec §4.3）—— 走 `PartyGiftSendService` 真调用 + `PartyBalanceSource` 真余额。
    ///
    /// - Parameter roomId: 派对房 id（DefaultPartyGiftSendService 内部 capture）
    /// - Parameter receivers: 麦位接受者列表（由 PartyGiftPanelBridge 构造）
    /// - Parameter sendService: 送礼 service（默认 `DefaultPartyGiftSendService(roomId:)`）
    /// - Parameter balance: 余额 source（默认 `PartyBalanceSource(service:)`）
    /// - Parameter onRecharge: tap "Recharge" 按钮触发；本轮建议挂 toast "充值功能开发中"
    /// - Parameter onSend: sendGift 成功回调（Store 内部已处理 phase.sent + 余额更新，此处仅供 caller 通知 UI 关面板等）
    ///
    /// MVP 收敛（spec §0.3）：仅 popular tab · 无背包（backpack .hidden）· 无 exclusive/lucky tab；
    /// H5 用户端 party-gift-popup.vue 3+ tab 待未来里程碑扩展
    static func partySend(roomId: String,
                          receivers: ReceiversConfig,
                          sendService: PartyGiftSendService? = nil,
                          balance: GiftPanelBalanceSource? = nil,
                          onRechargeRequested: @escaping () -> Void = {},
                          onSend: @escaping (_ gift: GiftListData, _ count: Int, _ yxAccidList: [String]) -> Void) -> Self {
        let effectiveSendService = sendService ?? DefaultPartyGiftSendService(roomId: roomId)
        // review #2 · balance 一体化：单一 PartyGiftDataSource 实例同时作 dataSource + balance source
        // response.userDiamond 内嵌 → 不额外调 gem/getBalance；避免余额展示与 sendGift 扣款域可能不一致的风险
        // caller 若显式传 balance 参数（如测试注入 mock）则优先使用
        let sharedDataSource = PartyGiftDataSource()
        let effectiveBalance: GiftPanelBalanceSource = balance ?? sharedDataSource
        return Self(
            tabs: [.popular],  // MVP: 仅 popular（spec §0.3）
            footer: .send(onSend: onSend, service: effectiveSendService),
            countStepper: .visible(range: 1...99),
            balance: .visible(source: effectiveBalance),
            backpack: .hidden,  // MVP 无背包（spec §0.3）
            receivers: receivers,
            interaction: .selectable,
            title: nil,
            dataSource: sharedDataSource,  // H-5 · 走 sapi 域 PartyAPI.getPartyRoomGift（不走 /api/gift/v3/getGiftList，后端不识别 PARTY_ROOM）
            onRechargeRequested: onRechargeRequested
        )
    }

    /// 1v1 通话索要礼物（H+ 1v1 场景接入；对齐 H5 `askForGift`）
    static func callAskFor(onAsk: @escaping (GiftListData) -> Void) -> Self {
        Self(
            tabs: [.popular],
            footer: .askFor(onAsk: onAsk),
            countStepper: .hidden,
            interaction: .selectable,
            title: L10n.callActionAskForGift,
            dataSource: DefaultGiftDataSource(scene: .call)
        )
    }
}
#endif
