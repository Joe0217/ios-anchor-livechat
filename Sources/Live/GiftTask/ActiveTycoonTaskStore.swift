import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "ActiveTycoonTaskStore")

/// Tab2 Active Tycoon Task 列表 store —— sheet 内 `@StateObject`(spec §1.1)。
///
/// **触发**:
/// - Sheet 创建时立即 `loadAsync`（对齐 H5 `watch(..., { immediate: true })`）
/// - 每次切回 Tab2 都重新请求（对齐 H5 active 由 false → true 时的 `load()`）
///
/// **状态机**(spec §1.2 v2):
/// - idle → loadAsync → loading → loaded / error
/// - loaded → refresh → refreshing(previous) → loaded(new) / error(empty)
///
/// **规则弹窗动态文案**:`firstTaskRuleText()` 供 sheet 外壳 rule overlay 优先使用。
@MainActor
final class ActiveTycoonTaskStore: ObservableObject {

    // MARK: - State

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded([ActiveTycoonTaskVO])
        case refreshing(previous: [ActiveTycoonTaskVO])
        case error(String)
        case errorWithPrevious([ActiveTycoonTaskVO], String)
    }

    @Published private(set) var loadState: LoadState = .idle

    /// 派生:当前展示的 tasks
    var tasks: [ActiveTycoonTaskVO] {
        switch loadState {
        case .loaded(let t), .refreshing(let t), .errorWithPrevious(let t, _):
            return t
        case .idle, .loading, .error:
            return []
        }
    }

    /// 派生:UI 是否显示 loading spinner
    var isLoading: Bool {
        switch loadState {
        case .loading: return true
        default: return false
        }
    }

    /// 派生:UI 是否显示空态
    var isEmpty: Bool {
        switch loadState {
        case .loaded(let t): return t.isEmpty
        case .error: return true
        case .errorWithPrevious(let t, _): return t.isEmpty
        case .idle, .loading, .refreshing: return false
        }
    }

    // MARK: - 依赖

    private let service: LiveGiftTaskServiceProtocol
    private var currentTask: Task<Void, Never>?

    init(service: LiveGiftTaskServiceProtocol = LiveGiftTaskServiceReal()) {
        self.service = service
    }

    deinit {
        currentTask?.cancel()
    }

    // MARK: - 公开入口

    /// H5 每次 active=true 都会调用 load，不能缓存跳过。
    func loadAsync() async {
        await refresh()
    }

    /// 显式重试(用户点击错误重试按钮触发)
    func refresh() async {
        currentTask?.cancel()

        let previousItems = tasks
        if previousItems.isEmpty {
            loadState = .loading
        } else {
            loadState = .refreshing(previous: previousItems)
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performFetch()
        }
        currentTask = task
        await task.value
    }

    /// 规则弹窗动态文案(对齐 H5 `getFirstTaskRule` — `taskList[0].taskRuleText?.trim() || ''`)
    /// - Returns: 非空字符串 = 用作 rule body;空字符串 = 外壳回退 i18n 默认文案
    func firstTaskRuleText() -> String {
        guard let text = tasks.first?.taskRuleText else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
    }

    /// Sheet dismiss / LiveRoomView disappear 时调
    func reset() {
        currentTask?.cancel()
        currentTask = nil
        loadState = .idle
    }

    // MARK: - 内部

    private func performFetch() async {
        do {
            try Task.checkCancellation()
            let list = try await service.fetchActiveTycoonTaskPanel()
            try Task.checkCancellation()
            loadState = .loaded(list)
            logger.info("Tycoon loaded count=\(list.count, privacy: .public)")
        } catch is CancellationError {
            logger.debug("Tycoon fetch cancelled")
        } catch {
            let msg = "\(error)"
            // H5 catch 将 taskList 置空；此处保留 loading 中的旧视觉，失败后切空态。
            loadState = .error(msg)
            logger.warning("Tycoon fetch failed: \(msg, privacy: .private)")
        }
    }
}
