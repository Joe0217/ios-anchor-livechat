import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "LiveGiftTaskStore")

/// 直播间礼物任务进度 store —— 由 [NIMChatroomManager](../NIMChatroomManager.swift) `let` 强所有,
/// 与 `contributionStore` / `topRankStore` 同排(spec §1.1 v2 决策)。
///
/// **触发链**(对齐 H5):
/// - 进房:[LiveRoomView.handleStoresInitialLoad](../LiveRoomView.swift) → `loadInitial()`
///   → 调 `getLiveGiftTask` 拉初始进度
/// - 收礼 IM:[NIMChatroomManager](../NIMChatroomManager.swift) `.liveGiftRankUpdate`(attachType 50) case
///   内追加 `refreshOnGift()`(**不挂 sendGift(1)/liveCallGift(4)**,对齐 H5 outer gate `attachType===50`
///   过滤,spec §2.4 v2)
/// - 离房:[LiveRoomView.handleOnDisappear](../LiveRoomView.swift) → `reset()`
///
/// **生命周期**:随 NIMChatroomManager 存续(nim 本身随 LiveRoomView 生命周期),自动无跨账号残留
/// → 无需挂 SessionStore.login/logout(spec §1.1 v2 一石二鸟消除 session-scoped rule 冲突)。
///
/// **竞态保护**:`refreshOnGift` 连续触发 → `currentTask.cancel()` + 新任务,保证只最后一次 assign
/// (spec §5.2 R-13)。
///
/// **状态机**([.refreshing pattern] 对齐直播场景 PKRecord/Props/PartyList):
/// - idle → loadInitial → loading → loaded / error
/// - loaded → refreshOnGift → refreshing(previous) → loaded(new) / errorWithPrevious(previous)
/// - error → 下次 IM 触发 → loading → loaded / error
/// - reset → idle
@MainActor
final class LiveGiftTaskStore: ObservableObject {

    // MARK: - State

    enum LoadState: Equatable {
        case idle
        case loading                                                // 首次(无 previous)
        case loaded(GiftTaskProgress)
        case refreshing(previous: GiftTaskProgress)                 // 有旧数据的刷新
        case error(String)                                          // 首次失败(无 previous)
        case errorWithPrevious(GiftTaskProgress, String)            // 刷新失败保留旧
    }

    @Published private(set) var loadState: LoadState = .idle

    /// 派生:当前展示的 giftTask(取 loaded / refreshing / errorWithPrevious 三态里的数据)。
    /// icon 显示条件 + 进度条 currentPoints/totalPoints 用此值。
    var giftTask: GiftTaskProgress? {
        switch loadState {
        case .loaded(let g), .refreshing(let g), .errorWithPrevious(let g, _):
            return g
        case .idle, .loading, .error:
            return nil
        }
    }

    /// 派生:顶部 Task icon 是否显示。
    var isIconVisible: Bool { giftTask?.hasActiveTask ?? false }

    // MARK: - 依赖

    private let service: LiveGiftTaskServiceProtocol
    private var currentTask: Task<Void, Never>?

    /// 主播 uid —— 严格对齐 H5 store 层 `getLiveGiftTask({searchValue: currentLiveInfo.userId})`(live.js:1013)。
    /// 由 `loadInitial(anchorUserId:)` 首次注入;`refreshOnGift()` 无参用此已存值(对齐 H5
    /// handleLiveGiftMessage 内 `updateLiveGiftTask()` 也是无参直调,内部从 store 拿 uid)
    private var anchorUserId: String = ""

    init(service: LiveGiftTaskServiceProtocol = LiveGiftTaskServiceReal()) {
        self.service = service
    }

    deinit {
        currentTask?.cancel()
    }

    // MARK: - 公开入口

    /// 进房时调 —— LiveRoomView.handleStoresInitialLoad 内与 contribution/topRank 同排。
    /// 首次注入主播 uid,后续 IM 触发的 refreshOnGift 直接复用。
    func loadInitial(anchorUserId: String) {
        self.anchorUserId = anchorUserId
        performLoad()
    }

    /// 收礼 IM 触发 —— NIMChatroomManager `.liveGiftRankUpdate` case 内调用。
    /// 无参:用 loadInitial 时存下的 anchorUserId(对齐 H5 `updateLiveGiftTask()` 无参调用)
    func refreshOnGift() {
        performLoad()
    }

    /// 离房清理 —— LiveRoomView.handleOnDisappear 内调用。
    func reset() {
        currentTask?.cancel()
        currentTask = nil
        anchorUserId = ""
        loadState = .idle
    }

    // MARK: - 内部

    private func performLoad() {
        currentTask?.cancel()

        // 状态迁移:idle/error → loading;loaded → refreshing(previous);errorWithPrevious → refreshing
        switch loadState {
        case .loaded(let g), .refreshing(let g), .errorWithPrevious(let g, _):
            loadState = .refreshing(previous: g)
        case .idle, .loading, .error:
            loadState = .loading
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performFetch()
        }
        currentTask = task
    }

    private func performFetch() async {
        do {
            try Task.checkCancellation()
            let progress = try await service.fetchLiveGiftTask(anchorUserId: anchorUserId)
            // 二次 checkCancellation:请求完成后可能已被 cancel(reset / 新 refresh 触发)
            try Task.checkCancellation()
            loadState = .loaded(progress)
            logger.info("LiveGiftTask loaded: giftTotal=\(progress.giftTotal, privacy: .public) taskAmount=\(progress.taskAmount ?? -1, privacy: .public)")
        } catch is CancellationError {
            // 静默:被更新的 task 覆盖,不改 state
            logger.debug("LiveGiftTask fetch cancelled")
        } catch {
            try? Task.checkCancellation()
            // 保留 previous 视觉不闪([list-refresh-preserve-items] rule)
            let msg = "\(error)"
            switch loadState {
            case .refreshing(let previous):
                loadState = .errorWithPrevious(previous, msg)
            case .loading, .idle, .error, .errorWithPrevious, .loaded:
                // loaded 分支理论上不会走到(performLoad 前已迁移到 refreshing);兜底保留 loaded
                if let g = giftTask {
                    loadState = .errorWithPrevious(g, msg)
                } else {
                    loadState = .error(msg)
                }
            }
            logger.warning("LiveGiftTask fetch failed: \(msg, privacy: .private)")
        }
    }
}
