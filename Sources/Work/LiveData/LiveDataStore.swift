import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "LiveDataStore")

/// Live Data 页视图模型。状态机 ≤5 态，切期间时保留前一次 payload
/// 供 View 展示"内容+overlay spinner"，避免闪空态（list-refresh-preserve-items rule §A）。
@MainActor
final class LiveDataStore: ObservableObject {

    /// - `idle`：首次未拉取
    /// - `loading(previous:)`：正在拉；previous nil = 首次全屏 spinner；non-nil = 覆盖在旧数据上
    /// - `loaded(data)`：拉取成功
    /// - `error(msg, previous:)`：失败；previous non-nil 时 View 仍显示旧数据 + 顶部错误 banner
    enum State {
        case idle
        case loading(previous: LiveDataResponse?)
        case loaded(LiveDataResponse)
        case error(String, previous: LiveDataResponse?)

        /// 当前可供 View 使用的 payload（loading/error 时的 previous 也算）
        var currentPayload: LiveDataResponse? {
            switch self {
            case .idle: return nil
            case .loading(let p): return p
            case .loaded(let p): return p
            case .error(_, let p): return p
            }
        }

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }

        var errorMessage: String? {
            if case .error(let msg, _) = self { return msg }
            return nil
        }
    }

    @Published private(set) var state: State = .idle
    /// 当前查询期间；默认 `.thisWeek`（对齐 H5 `tabActive.value = 0` + `showDownUpValue.value = 0`）
    @Published private(set) var dateType: LiveDataDateType = .thisWeek
    /// 浮标钻石数（懒拉一次；失败静默 0，不影响主数据展示）
    @Published private(set) var sureGetAward: Int = 0
    /// 日期行展开集合（key = statDate）。提升到 Store 让每次 reload 成功后可清空
    /// —— 对齐 H5 `getData` 里 `item.openStatus = false` 每次强制归零。
    @Published private(set) var expandedDates: Set<String> = []

    private let service: LiveDataServiceProtocol
    private var currentTask: Task<Void, Never>?
    private var moneyBagLoaded = false

    init(service: LiveDataServiceProtocol = LiveDataService.shared) {
        self.service = service
    }

    /// 页面首次出现调（懒加载，避免 Preview 拉真接口）
    func onAppear() {
        if case .idle = state { reload() }
        if !moneyBagLoaded { loadMoneyBag() }
    }

    /// 用户 tap 期间 tab / 下拉子期间 —— 语义="用户主动请求刷新"，对齐 H5 无条件 getData()。
    /// 值变时切 dateType；值不变时直接 reload（H5 handleTabClick / chooseItem 都无 equality check）。
    func tapDateType(_ newValue: LiveDataDateType) {
        if newValue != dateType {
            dateType = newValue
        }
        reload()
    }

    /// 同期间重新拉取（error 重试用；tap 期间也调这里）
    func reload() {
        currentTask?.cancel()
        let previous = state.currentPayload
        state = .loading(previous: previous)
        let dt = dateType
        currentTask = Task { @MainActor in
            do {
                let resp = try await service.fetchLiveData(dateType: dt)
                // 防越权覆盖：拉取期间用户又切了期间 → 当前 dateType 已不是 dt，丢弃
                guard !Task.isCancelled, self.dateType == dt else { return }
                state = .loaded(resp)
                // 每次成功 reload 后清空日期行展开态（对齐 H5 `item.openStatus = false`）
                expandedDates.removeAll()
            } catch {
                guard !Task.isCancelled, self.dateType == dt else { return }
                let msg = (error as? APIError)?.message ?? error.localizedDescription
                logger.error("fetchLiveData failed dateType=\(dt.rawValue) err=\(msg, privacy: .public)")
                state = .error(msg, previous: previous)
            }
        }
    }

    /// 单行日期展开态切换（提到 Store 让 reload 成功后可批量清空）
    func toggleExpanded(_ statDate: String) {
        if expandedDates.contains(statDate) {
            expandedDates.remove(statDate)
        } else {
            expandedDates.insert(statDate)
        }
    }

    /// 拉取浮标钻石数。失败静默（H5 也没 error UI）
    private func loadMoneyBag() {
        Task { @MainActor in
            do {
                let resp = try await service.fetchMoneyBag()
                self.sureGetAward = resp.sureGetAward
                self.moneyBagLoaded = true
            } catch {
                logger.warning("fetchMoneyBag failed: \(String(describing: error), privacy: .public)")
                // 不 flip moneyBagLoaded，允许下次 onAppear 重试
            }
        }
    }
}
