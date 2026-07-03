import Foundation
import SwiftUI
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "AppPictureStore")

/// 全局图片配置单例：跨模块共享（首页 banner / 榜单 / 挂件 / 分类贴图 等复用同一接口）。
///
/// 对齐 H5 `homeStore.bannerList`（`stores/modules/home.js`）+ 启动时 `getBannerList([2])`
/// （`stores/modules/app.js:115`）。
///
/// 设计：
/// - 按 type 分桶缓存，任一桶字段变化仅 fire `objectWillChange` 一次
/// - 消费方通过派生 bridge 订阅特定 type + position，避免整表变化触发无关 view rebuild
///   （见 `.claude/rules/swiftui-keepalive-publisher-isolation.md`）
/// - `loadIfNeeded(types:)` 首次触发（app 启动 or home tab 首次可见时调用），已加载过不重发
/// - `refresh(types:)` 用户主动刷新（下拉 / 配置变更）
///
/// 未持久化（H5 也不持久化，进程内缓存即可；下次冷启动会重新拉）。
@MainActor
final class AppPictureStore: ObservableObject {

    static let shared = AppPictureStore()

    /// 按 type 分桶存储。
    @Published private(set) var pictures: [AppPictureType: [AppPictureItem]] = [:]

    /// 已加载过的 type 集合（`loadIfNeeded` 幂等依据）。
    @Published private(set) var loadedTypes: Set<AppPictureType> = []

    private let service: AppPictureServiceProtocol
    private var inflight: Task<Void, Never>?

    init(service: AppPictureServiceProtocol = AppPictureService.shared) {
        self.service = service
    }

    /// 首次拉取指定 types；已加载过的直接跳过。
    /// 命中同时有 inflight 任务时，等待其结束（避免重复请求）。
    func loadIfNeeded(types: [AppPictureType]) async {
        let missing = types.filter { !loadedTypes.contains($0) }
        guard !missing.isEmpty else { return }
        if let inflight {
            await inflight.value
            // inflight 完成后再复查——避免同一 type 由两次调用重复请求
            let stillMissing = types.filter { !loadedTypes.contains($0) }
            guard !stillMissing.isEmpty else { return }
            await performLoad(types: stillMissing)
            return
        }
        await performLoad(types: missing)
    }

    /// 强制刷新（跳过 loadedTypes 判定）。
    func refresh(types: [AppPictureType]) async {
        if let inflight { await inflight.value }
        await performLoad(types: types)
    }

    /// 按 type 取（消费方通常配合 filter 使用）。
    func items(of type: AppPictureType) -> [AppPictureItem] {
        pictures[type] ?? []
    }

    /// 按 type + 归属位过滤——对齐 H5 `bannerPosition?.includes(position)`。
    func items(of type: AppPictureType, position: String) -> [AppPictureItem] {
        items(of: type).filter { $0.belongsTo(position: position) }
    }

    /// 登出清空（对齐 SessionStore.logout 语义）。
    func clear() {
        inflight?.cancel()
        inflight = nil
        pictures = [:]
        loadedTypes = []
    }

    // MARK: - private

    private func performLoad(types: [AppPictureType]) async {
        // 请求生命周期隔离——Task.detached 让请求不受调用侧 view cancel 传播影响；
        // 对齐 AnchorInfoStore / LiveStreamViewModel / GiftMarqueeStore 同款模式，
        // 未来 J 里程碑下游 short-lived view 用 `.task { store.loadIfNeeded(...) }` 也不踩 -999
        // （202607031151 审查建议-3）。
        let task = Task.detached { @MainActor [self] in
            await doLoad(types: types)
        }
        inflight = task
        await task.value
        inflight = nil
    }

    private func doLoad(types: [AppPictureType]) async {
        do {
            let result = try await service.fetchPictures(types: types)
            // 只覆盖本次拉到的 type 桶，别的 type 保留
            for type in types {
                pictures[type] = result[type] ?? []
                loadedTypes.insert(type)
            }
            let counts = types.map { "\($0.rawValue)=\(pictures[$0]?.count ?? 0)" }.joined(separator: ",")
            logger.info("loaded \(counts, privacy: .public)")
        } catch let e as APIError {
            logger.error("load APIError code=\(e.code) message=\(e.message)")
        } catch {
            logger.error("load error: \(String(describing: error))")
        }
    }
}
