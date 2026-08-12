import Foundation
import SwiftUI
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "GiftMarqueeStore")

/// 首页跑马灯 store。
///
/// 对齐 H5 `getLiveMarqueeListData()`——H5 每次进 Live 广场时调一次；这里做进程内缓存，
/// 避免每次 view 挂载/切走再回都重新拉（用户不高频关心跑马灯变化）。
/// 用户主动下拉刷新时（同 refreshable）走 `refresh()` 强拉一次。
///
/// **请求生命周期隔离**：Task.detached 避免 view cancel 传播到 URLSession（AnchorInfoStore
/// / LiveStreamViewModel 同款模式）。
@MainActor
final class GiftMarqueeStore: ObservableObject {

    static let shared = GiftMarqueeStore()

    @Published private(set) var items: [GiftMarqueeItem] = []
    @Published private(set) var hasLoadedOnce: Bool = false

    private let service: GiftMarqueeServiceProtocol
    private var inflightTask: Task<Void, Never>?
    private var dataGeneration = 0

    init(service: GiftMarqueeServiceProtocol = GiftMarqueeService.shared) {
        self.service = service
    }

    /// 首次加载：已加载过 → 跳过。
    func loadIfNeeded() async {
        if hasLoadedOnce { return }
        if let inflightTask {
            await inflightTask.value
            return
        }
        await performReload()
    }

    /// 强制刷新（下拉 / 定时轮询）。
    func refresh() async {
        if let inflightTask {
            await inflightTask.value
            return
        }
        await performReload()
    }

    /// 登出清空。
    func clear() {
        dataGeneration &+= 1
        inflightTask?.cancel()
        inflightTask = nil
        items = []
        hasLoadedOnce = false
    }

    // MARK: - private

    private func performReload() async {
        let generation = dataGeneration
        let task = Task.detached { @MainActor [self] in
            await doReload(generation: generation)
        }
        inflightTask = task
        await task.value
        if generation == dataGeneration, inflightTask == task {
            inflightTask = nil
        }
    }

    private func doReload(generation: Int) async {
        guard generation == dataGeneration else { return }
        do {
            let list = try await service.fetchMarquee()
            guard generation == dataGeneration, !Task.isCancelled else { return }
            items = list
            hasLoadedOnce = true
            logger.info("loaded marquee count=\(list.count)")
        } catch let e as APIError {
            guard generation == dataGeneration, !Task.isCancelled else { return }
            logger.error("load APIError code=\(e.code) message=\(e.message, privacy: .public)")
        } catch {
            guard generation == dataGeneration, !Task.isCancelled else { return }
            logger.error("load error: \(String(describing: error), privacy: .public)")
        }
    }
}
