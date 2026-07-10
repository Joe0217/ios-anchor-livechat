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
    /// 周等级字面量（D/C/NEW/B/A/S/SS）—— 派生自 info.levelName / info.level（对齐 H5 mineInfo.userLevel）
    @Published var weeklyLevel: String = ""

    /// 场景文案（对齐 H5 getLevelText 分支）：
    /// - SS → "You are a top host"
    /// - S  → "Keep S-tier to become an SS-tier"
    /// - 未达通话目标 → "Call target not met"
    /// - 已达 + 有数据 → "Average Call Time XX (nextLevel YY)"
    /// - 无有效数据 → ""
    /// 接接口前用 SS 占位文案。
    var levelText: String { L10n.workLevelTextTopHost }

    // MARK: - 三项概览（对齐 H5 hostDashboard: onlineTime / avgCallDuration / positiveRating）
    /// 今日在线时长（秒）—— H5: dataStatistics.callNum
    @Published var onlineTimeSec: Int = 0
    /// 平均通话时长（秒）—— H5: dataStatistics.weeklyDiamonds（字段名 H5 复用，业务是时长）
    @Published var avgCallDurationSec: Int = 0
    /// 好评率（百分比整数）—— H5: dataStatistics.positiveRating
    @Published var positiveRating: Int = 0

    // MARK: - 今日收益（H5 anchorIncomeMap.{callIncome/giftIncome/taskReward/invitationReward/unlock/totalCoin}）
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

    init() {
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

        // 周等级字面量（对齐 AnchorInfoStore.tierLabel 逻辑，H5 mineInfo.userLevel）
        AnchorInfoStore.shared.$info
            .combineLatest(AnchorInfoStore.shared.$mine)
            .map { info, mine -> String in
                if let n = info?.levelName, !n.isEmpty { return n }
                if let lvl = info?.level { return AnchorInfoStore.tierName(forLevel: lvl) }
                if let n = mine?.levelName, !n.isEmpty { return n }
                if let lvl = mine?.level { return AnchorInfoStore.tierName(forLevel: lvl) }
                return ""
            }
            .removeDuplicates()
            .assign(to: &$weeklyLevel)

        // dataStatistics 三项（H5 work/index.vue L498/509/520）
        AnchorInfoStore.shared.$info
            .map { $0?.dataStatistics?.callNum ?? 0 }
            .removeDuplicates()
            .assign(to: &$onlineTimeSec)
        AnchorInfoStore.shared.$info
            .map { $0?.dataStatistics?.weeklyDiamonds ?? 0 }
            .removeDuplicates()
            .assign(to: &$avgCallDurationSec)
        AnchorInfoStore.shared.$info
            .map { $0?.dataStatistics?.positiveRating ?? 0 }
            .removeDuplicates()
            .assign(to: &$positiveRating)

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
            .map { $0?.anchorIncomeMap?.unlock ?? "0" }
            .removeDuplicates()
            .assign(to: &$managedIncomes)
        AnchorInfoStore.shared.$info
            .map { $0?.anchorIncomeMap?.totalCoin ?? "0" }
            .removeDuplicates()
            .assign(to: &$totalIncomes)

        // 并行拉两个 visibility 接口（H5 Promise.allSettled 语义：任一失败不阻塞另一个，
        // 失败态默认 false 与 H5 一致）。
        Task { @MainActor [weak self] in
            async let newbie = Self.fetchVisible(path: "/api/anchor/newTask/checkEntryVisible", tag: "newbie")
            async let bigR = Self.fetchVisible(path: "/api/anchor/bigr/entryVisible", tag: "bigR")
            let (n, b) = await (newbie, bigR)
            guard let self else { return }
            self.showNewbie = n
            self.showBigR = b
        }
    }

    /// 下拉刷新（对齐 H5 `userStore.getMineInfoData(true)` + `listOnRefresh`）。
    /// - `async` 必要：`.refreshable` closure await 到本函数完成才收顶部 spinner，
    ///   否则手势 release 时 spinner 一闪即隐（rule list-refresh-preserve-items §B）
    /// - 同时刷新工具入口 visibility（对齐 H5 listOnRefresh 语义）
    func refresh() async {
        async let anchorRefresh: Void = AnchorInfoStore.shared.refresh()
        async let newbie = Self.fetchVisible(path: "/api/anchor/newTask/checkEntryVisible", tag: "newbie")
        async let bigR = Self.fetchVisible(path: "/api/anchor/bigr/entryVisible", tag: "bigR")
        let (_, n, b) = await (anchorRefresh, newbie, bigR)
        self.showNewbie = n
        self.showBigR = b
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
