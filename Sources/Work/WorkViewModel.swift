import SwiftUI
import Combine
import Foundation

/// Work（工作台）页数据源。
///
/// 数据来源：`AnchorInfoStore.shared.info`（`/api/anchor/userInfo` 响应），对齐 H5 蓝本
/// `anchor-livechat-h5/src/views/work/index.vue` 的 `userStore.mineInfo`。
/// 副作用（拉取 / 刷新 / 在线态切换）收敛进此处或 AnchorInfoStore，View 只读 @Published。
///
/// 派生策略：订阅底层 `$info` + `removeDuplicates()`（遵循 swiftui-keepalive-publisher-isolation
/// 派生守门模式，避免 keep-alive 下 followingCount 等无关字段变化触发本 view body 重算）。
@MainActor
final class WorkViewModel: ObservableObject {

    // MARK: - 周等级
    /// 头像 URL —— 派生自 AnchorInfoStore.$info / $mine / SessionStore.user.icon（对齐 H5 mine.icon 优先）。
    @Published var avatarURL: URL?
    /// 周等级字面量（D/C/NEW/B/A/S/SS）—— 优先 H5 同源的 info.userLevel。
    @Published var weeklyLevel: String = ""

    /// 场景文案（对齐 H5 getLevelText 分支）：
    /// - SS → "You are a top host"
    /// - S  → "Keep S-tier to become an SS-tier"
    /// - 未达通话目标 → "Call target not met"
    /// - 已达 + 有数据 → "Average Call Time XX (nextLevel YY)"
    /// - 无有效数据 → ""
    var levelText: String {
        guard let info = AnchorInfoStore.shared.info ?? AnchorInfoStore.shared.mine else { return "" }
        if info.userLevel == "SS" { return L10n.workLevelTextTopHost }
        if info.userLevel == "S" { return L10n.workLevelTextKeepSTier }
        if info.isCallTarget == false { return L10n.workLevelTextCallTargetNotMet }
        guard let duration = info.anchorSettleMap?.averageCallDuration else { return "" }
        var text = "\(L10n.workLevelTextAverageCallTime)\(Self.timeString(duration))"
        if let nextLevel = info.nextLevel, !nextLevel.isEmpty {
            text += "\(L10n.workLevelTextNextLevel)\(nextLevel))"
        }
        return text
    }

    // MARK: - 三项概览（对齐 H5 hostDashboard: onlineTime / avgCallDuration / positiveRating）
    /// 今日在线时长（秒）—— H5 `anchorSettleMap.onlineTime`。
    @Published var onlineTimeSec: Int = 0
    /// 平均通话时长（秒）—— H5 `anchorSettleMap.averageCallDuration`。
    @Published var avgCallDurationSec: Int = 0
    /// 好评率（百分比整数）—— H5: dataStatistics.positiveRating
    @Published var positiveRating: Int = 0

    // Android Work 专属的概览卡字段；H5 当前未启用这组卡片。
    @Published var dailyCalls: Int = 0
    @Published var weeklyCoins: Int = 0
    @Published var walletDiamonds: Int64 = 0
    @Published var walletGems: Int64 = 0

    /// 官方 WhatsApp 客服号（H5 `getConfigByKey({searchValue: 'WhatsApp'})`）。
    /// 空串表示未拉到或未配置，Footer 里空时整行隐藏（fail-silent）。
    @Published var whatsappPhone: String = ""

    // MARK: - 今日收益（H5 anchorIncomeMap.{callIncome,giftIncome,taskReward,invitationReward,othersIncome,totalCoin}）
    /// 值来自后端字符串（H5 蓝本 `|| '0'` 兜底），保留 String 类型避免精度丢失
    @Published var callIncomes: String = "0"
    @Published var giftIncomes: String = "0"
    @Published var taskIncomes: String = "0"
    @Published var inviteIncomes: String = "0"
    @Published var managedIncomes: String = "0"
    @Published var totalIncomes: String = "0"

    // MARK: - 在线开关
    /// 下线确认弹窗展示（H5 useStandardPopup 交互）—— 页级状态，不共享
    @Published var showOfflineConfirm: Bool = false

    /// 在线态读 shared store 的 `userSetOnline`（Work 开关反映用户手动意愿，不含 WS / forcedBusy 派生）。
    var isOnline: Bool { OnlineStatusStore.shared.userSetOnline }

    /// 段位刻度（与设计稿一致）
    let tiers: [String] = ["D", "C", "NEW", "B", "A", "S", "SS"]

    // MARK: - 动态工具入口 visibility（对齐 H5 work/index.vue onMounted 并行拉取）
    /// 新手任务入口是否显示 —— 对齐 H5 `getCheckEntryVisibleApi().visible`
    @Published private(set) var showNewbie: Bool = false
    /// Star User（大 R）入口是否显示 —— 对齐 H5 `getBigREntryVisibleApi().visible`
    @Published private(set) var showBigR: Bool = false
    /// 成长中心存在尚未查看的模块时显示红点（对齐 H5 `/api/anchor/guide/list` + moduleKey 已读集合）。
    @Published private(set) var hasAnchorGuideRedDot: Bool = false

    private var anchorGuideModuleKeys = Set<String>()
    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: .anchorGuideModuleViewed)
            .compactMap { $0.userInfo?["moduleKey"] as? String }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] moduleKey in
                self?.markAnchorGuideModuleViewed(moduleKey)
            }
            .store(in: &cancellables)

        // 派生头像 URL：follow AnchorInfoStore.iconURL 优先级（info.icon → mine.icon → session.user.icon）。
        // 只订阅 $info/$mine 两个字段（不 @ObservedObject 大 store），登出→登录切账号时会因
        // AnchorInfoStore.clear + login refresh 双入口自动重刷（rule session-scoped-store-refresh）。
        AnchorInfoStore.shared.$info
            .combineLatest(AnchorInfoStore.shared.$mine)
            .map { info, mine -> URL? in
                let s = info?.icon ?? mine?.icon ?? SessionStore.shared.user?.icon ?? ""
                guard !s.isEmpty else { return nil }
                return URL(string: s)
            }
            .removeDuplicates()
            .assign(to: &$avatarURL)

        // 周等级字面量：H5 实际展示 mineInfo.userLevel，兼容旧字段 levelName / level。
        AnchorInfoStore.shared.$info
            .combineLatest(AnchorInfoStore.shared.$mine)
            .map { info, mine -> String in
                if let n = info?.userLevel, !n.isEmpty { return n }
                if let n = info?.levelName, !n.isEmpty { return n }
                if let lvl = info?.level { return AnchorInfoStore.tierName(forLevel: lvl) }
                if let n = mine?.userLevel, !n.isEmpty { return n }
                if let n = mine?.levelName, !n.isEmpty { return n }
                if let lvl = mine?.level { return AnchorInfoStore.tierName(forLevel: lvl) }
                return ""
            }
            .removeDuplicates()
            .assign(to: &$weeklyLevel)

        // H5 Work 三项：anchorSettleMap 两个时长 + dataStatistics.positiveRating。
        AnchorInfoStore.shared.$info
            .map { $0?.anchorSettleMap?.onlineTime ?? 0 }
            .removeDuplicates()
            .assign(to: &$onlineTimeSec)
        AnchorInfoStore.shared.$info
            .map { $0?.anchorSettleMap?.averageCallDuration ?? 0 }
            .removeDuplicates()
            .assign(to: &$avgCallDurationSec)
        AnchorInfoStore.shared.$info
            .map { $0?.dataStatistics?.positiveRating ?? 0 }
            .removeDuplicates()
            .assign(to: &$positiveRating)
        AnchorInfoStore.shared.$info
            .map { $0?.dataStatistics?.callNum ?? 0 }
            .removeDuplicates()
            .assign(to: &$dailyCalls)
        AnchorInfoStore.shared.$info
            .map { $0?.dataStatistics?.weeklyDiamonds ?? 0 }
            .removeDuplicates()
            .assign(to: &$weeklyCoins)

        // anchorIncomeMap 六项（H5 work/index.vue L279 mappedIncomeItems，值 || '0' 兜底）
        AnchorInfoStore.shared.$info
            .map { $0?.anchorIncomeMap?.callIncome ?? "0" }
            .removeDuplicates()
            .assign(to: &$callIncomes)
        AnchorInfoStore.shared.$info
            .map { $0?.anchorIncomeMap?.giftIncome ?? "0" }
            .removeDuplicates()
            .assign(to: &$giftIncomes)
        AnchorInfoStore.shared.$info
            .map { $0?.anchorIncomeMap?.taskReward ?? "0" }
            .removeDuplicates()
            .assign(to: &$taskIncomes)
        AnchorInfoStore.shared.$info
            .map { $0?.anchorIncomeMap?.invitationReward ?? "0" }
            .removeDuplicates()
            .assign(to: &$inviteIncomes)
        AnchorInfoStore.shared.$info
            .map { $0?.anchorIncomeMap?.othersIncome ?? "0" }
            .removeDuplicates()
            .assign(to: &$managedIncomes)
        AnchorInfoStore.shared.$info
            .map { $0?.anchorIncomeMap?.totalCoin ?? "0" }
            .removeDuplicates()
            .assign(to: &$totalIncomes)

        // H5 共用的工具探针，外加 Android Work 的余额概览。
        Task { @MainActor [weak self] in
            async let newbie = Self.fetchVisible(path: "/api/anchor/newTask/checkEntryVisible", tag: "newbie")
            async let bigR = Self.fetchVisible(path: "/api/anchor/bigr/entryVisible", tag: "bigR")
            async let balance = Self.fetchWalletBalance()
            async let whatsapp = Self.fetchWhatsapp()
            async let anchorGuideKeys = Self.fetchAnchorGuideModuleKeys()
            let (n, b, balanceResult, wa, guideKeys) = await (newbie, bigR, balance, whatsapp, anchorGuideKeys)
            guard let self else { return }
            self.showNewbie = n
            self.showBigR = b
            self.walletDiamonds = balanceResult.diamond
            self.walletGems = balanceResult.gem
            self.whatsappPhone = wa
            self.updateAnchorGuideRedDot(moduleKeys: guideKeys)
        }
    }

    /// 下拉刷新（对齐 H5 `userStore.getMineInfoData(true)` + `listOnRefresh`）。
    /// - `async` 必要：`.refreshable` closure await 到本函数完成才收顶部 spinner，
    ///   否则手势 release 时 spinner 一闪即隐（rule list-refresh-preserve-items §B）
    /// - H5 下拉刷新刷新主播资料和成长中心红点；其它工具探针保留首次进入结果。
    func refresh() async {
        async let anchorRefresh: Void = AnchorInfoStore.shared.refresh()
        async let whatsapp = Self.fetchWhatsapp()
        async let anchorGuideKeys = Self.fetchAnchorGuideModuleKeys()
        let (_, wa, guideKeys) = await (anchorRefresh, whatsapp, anchorGuideKeys)
        self.whatsappPhone = wa
        updateAnchorGuideRedDot(moduleKeys: guideKeys)
    }

    /// 仅在用户展开了 H5 成长中心模块后标记该模块已读，避免“只进入页面就清空所有提醒”。
    private func markAnchorGuideModuleViewed(_ rawModuleKey: String) {
        let moduleKey = rawModuleKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !moduleKey.isEmpty else { return }
        var readKeys = Set(UserDefaults.standard.stringArray(forKey: anchorGuideReadKeysStorageKey) ?? [])
        guard readKeys.insert(moduleKey).inserted else { return }
        UserDefaults.standard.set(Array(readKeys), forKey: anchorGuideReadKeysStorageKey)
        hasAnchorGuideRedDot = anchorGuideModuleKeys.contains { !readKeys.contains($0) }
    }

    /// POST 无 body 拉 `{visible: Bool}`。失败静默返 false（对齐 H5 allSettled fail-silent）。
    /// String/Int/NSNumber/Bool 三兼容 decode（follow rule ios-decode-userid-compat 精神）。
    private static func fetchVisible(path: String, tag: String) async -> Bool {
        do {
            let data = try await APIClient.shared.post(path, body: nil)
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                AppLogger.net.error("[Work.\(tag, privacy: .public)] visibility response not dict")
                return false
            }
            if let b = dict["visible"] as? Bool { return b }
            if let n = dict["visible"] as? NSNumber {
                let c = String(cString: n.objCType)
                if c == "c" || c == "B" { return n.boolValue }
                return n.intValue != 0
            }
            if let s = dict["visible"] as? String { return s.lowercased() == "true" || s == "1" }
            return false
        } catch {
            AppLogger.net.error("[Work.\(tag, privacy: .public)] visibility fetch failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// H5 以 `/api/anchor/guide/list` 返回的 moduleKey 与本地已读集合求差来决定入口红点。
    /// 空响应或请求失败返回 nil；调用方会使用上次成功保存的模块快照，避免离线时误灭。
    private static func fetchAnchorGuideModuleKeys() async -> Set<String>? {
        do {
            let data = try await APIClient.shared.post("/api/anchor/guide/list", body: nil)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tabs = object["tabs"] as? [[String: Any]] else {
                AppLogger.net.error("[Work.anchorGuide] list response invalid")
                return nil
            }
            var keys = Set<String>()
            for tab in tabs {
                let modules = tab["modules"] as? [[String: Any]] ?? []
                for module in modules {
                    guard let key = module["moduleKey"] as? String else { continue }
                    let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !normalized.isEmpty {
                        keys.insert(normalized)
                    }
                }
            }
            return keys
        } catch {
            AppLogger.net.error("[Work.anchorGuide] list fetch failed: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    private func updateAnchorGuideRedDot(moduleKeys: Set<String>?) {
        let resolvedModuleKeys: Set<String>
        if let moduleKeys, !moduleKeys.isEmpty {
            resolvedModuleKeys = moduleKeys
            UserDefaults.standard.set(Array(moduleKeys), forKey: anchorGuideModuleKeysStorageKey)
        } else {
            resolvedModuleKeys = Set(UserDefaults.standard.stringArray(forKey: anchorGuideModuleKeysStorageKey) ?? [])
        }
        anchorGuideModuleKeys = resolvedModuleKeys
        guard !resolvedModuleKeys.isEmpty else {
            // 与 H5 相同：首次无法获得内容快照时保留提醒；已知列表为空时不会写快照，因此也不误灭旧状态。
            hasAnchorGuideRedDot = UserDefaults.standard.object(forKey: anchorGuideModuleKeysStorageKey) == nil
            return
        }
        let readKeys = Set(UserDefaults.standard.stringArray(forKey: anchorGuideReadKeysStorageKey) ?? [])
        hasAnchorGuideRedDot = resolvedModuleKeys.contains { !readKeys.contains($0) }
    }

    private var anchorGuideReadKeysStorageKey: String {
        "anchorGuide.readKeys.\(anchorGuideUserID)"
    }

    private var anchorGuideModuleKeysStorageKey: String {
        "anchorGuide.allKeys.\(anchorGuideUserID)"
    }

    private var anchorGuideUserID: Int {
        let userID = SessionStore.shared.user?.userId
            ?? AnchorInfoStore.shared.info?.userId
            ?? AnchorInfoStore.shared.mine?.userId
            ?? 0
        return userID
    }

    /// Android Work 专属钻石/宝石概览：sapi `gem/getBalance`。
    private static func fetchWalletBalance() async -> (diamond: Int64, gem: Int64) {
        do {
            let data = try await PartyAPIClient.shared.post(
                "/sapi/weidou/v1/client/gem/getBalance",
                body: [:]
            )
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (0, 0)
            }
            return (
                extractInt64(from: object, keys: ["diamond", "diamonds", "diamondNum"]),
                extractInt64(from: object, keys: ["gem", "gems"])
            )
        } catch {
            AppLogger.net.error("[Work.balance] fetch failed: \(String(describing: error), privacy: .private)")
            return (0, 0)
        }
    }

    private static func extractInt64(from object: [String: Any], keys: [String]) -> Int64 {
        for key in keys {
            if let number = object[key] as? NSNumber {
                let type = String(cString: number.objCType)
                if type != "c" && type != "B" { return number.int64Value }
            }
            if let string = object[key] as? String, let value = Int64(string) {
                return value
            }
        }
        return 0
    }

    /// 拉官方 WhatsApp 客服号（对齐 H5 `getConfigByKey({searchValue: 'WhatsApp'})`）。
    /// 失败静默返空串（fail-silent；Footer 空则隐藏该行）。
    private static func fetchWhatsapp() async -> String {
        do {
            let dict = try await AppConfigService.fetch(keys: ["WhatsApp"])
            if let s = dict["WhatsApp"] as? String { return s }
            if let n = dict["WhatsApp"] as? NSNumber { return n.stringValue }
            return ""
        } catch {
            AppLogger.net.error("[Work.whatsapp] fetch failed: \(String(describing: error), privacy: .private)")
            return ""
        }
    }

    private static func timeString(_ seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }

    /// 点击开关：上线直改；下线走确认弹窗（H5 changeOnline 分支）
    func requestToggleOnline() {
        if isOnline {
            showOfflineConfirm = true
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                OnlineStatusStore.shared.setUserSetOnline(true)
            }
        }
    }

    /// 用户确认下线
    func confirmGoOffline() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            OnlineStatusStore.shared.setUserSetOnline(false)
        }
        showOfflineConfirm = false
    }
}

extension Notification.Name {
    static let anchorGuideModuleViewed = Notification.Name("anchorGuideModuleViewed")
}
