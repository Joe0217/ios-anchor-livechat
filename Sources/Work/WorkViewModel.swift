import SwiftUI

/// Work（工作台）页数据源。
///
/// 当前为对齐 H5 主播端（`anchor-livechat-h5/src/views/work/index.vue`）的占位数据，
/// 数值取自 H5 页面同名字段。后续里程碑接入 `getMineInfoData` 时，副作用（拉取 / 刷新
/// / 在线态切换）收敛进此处或对应 Store，View 只读 @Published。
@MainActor
final class WorkViewModel: ObservableObject {

    // MARK: - 周等级
    @Published var avatarURL: URL?                 // 占位：暂无头像资源，渲染默认环
    @Published var weeklyLevel: String = "SS"

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
    @Published var onlineTimeSec: Int = 3600 * 6 + 420
    /// 平均通话时长（秒）—— H5: dataStatistics.weeklyDiamonds（字段名 H5 复用，业务是时长）
    @Published var avgCallDurationSec: Int = 128
    /// 好评率（百分比整数）—— H5: dataStatistics.positiveRating
    @Published var positiveRating: Int = 98

    // MARK: - 今日收益
    @Published var callIncomes: Int = 222
    @Published var giftIncomes: Int = 1280
    @Published var taskIncomes: Int = 1280
    @Published var inviteIncomes: Int = 128
    @Published var managedIncomes: Int = 950
    @Published var totalIncomes: Int = 99999

    // MARK: - 在线开关
    /// 下线确认弹窗展示（H5 useStandardPopup 交互）—— 页级状态，不共享
    @Published var showOfflineConfirm: Bool = false

    /// 在线态读 shared store 的 `userSetOnline`（Work 开关反映用户手动意愿，不含 WS / forcedBusy 派生）。
    var isOnline: Bool { OnlineStatusStore.shared.userSetOnline }

    /// 段位刻度（与设计稿一致）
    let tiers: [String] = ["D", "C", "NEW", "B", "A", "S", "SS"]

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
