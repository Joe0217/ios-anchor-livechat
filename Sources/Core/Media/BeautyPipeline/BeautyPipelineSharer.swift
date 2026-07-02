import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "BeautyPipelineSharer")

/// 美颜管线共享基建（K spec §3.1 复合状态机 + §6.1 #1）。
///
/// 职责：
/// 1. **setup 状态机**（红队 A3）：`.notStarted / .inProgress / .ready / .failed`；
///    多 view 并发首次访问返回同一 Task 不重跑
/// 2. **activeSubscriber 优先级栈**（红队 B1）：`Live > Call > Party > Preview`；
///    仅栈顶 owner 的参数更新走 renderer，其他 subscriber 只读 Store 不写 SDK
/// 3. **pendingSettings 队列**（红队 D1）：setup 未 ready 时缓冲 Store 变化，
///    ready 后一次 replay 到栈顶 renderer
/// 4. **中断态阻断 SDK**（红队 F4）：AVCaptureSession 中断期间 Sharer.apply no-op
/// 5. **degraded 态**（红队 A5 / B4）：setup 失败走 PassthroughRenderer，
///    UI 层订阅 setupState 挂横幅
///
/// 与 CameraManager 关系（Step 1a 骨架版）：
/// - 本 step 只落 Sharer 类骨架 + Store 订阅
/// - Step 2 接线时 CameraManager / view 层调用 `attach(_:token:)` / `detach(_:)`
/// - Sharer 不直接引用 CameraManager，通过 weak renderer 引用协调
@MainActor
final class BeautyPipelineSharer: ObservableObject {

    // MARK: - Singleton

    static let shared = BeautyPipelineSharer()

    // MARK: - Setup 状态机（红队 A3）

    enum SetupState: Equatable {
        case notStarted
        case inProgress
        case ready
        case failed(BeautyError)
    }

    @Published private(set) var setupState: SetupState = .notStarted

    /// 若正在 setup，多 view 并发访问返回同一 Task（防重跑）
    private var setupTask: Task<Void, Never>?

    // MARK: - Subscriber 优先级栈（红队 B1）

    /// 订阅者身份标识。优先级：`live > call > party > preview`（数值越大越高优先级）
    enum SubscriberToken: Int, Comparable {
        case preview = 1
        case party = 2
        case call = 3
        case live = 4

        static func < (lhs: SubscriberToken, rhs: SubscriberToken) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// 弱引用 renderer + token 二元组。renderer nil 时视为无效栈项，subscribers 遍历时跳过
    private struct SubscriberEntry {
        weak var renderer: (AnyObject & BeautyRenderer)?
        let token: SubscriberToken
    }

    /// 订阅栈（保留插入顺序 + 按 token 优先级判断栈顶；同 token 后 push 覆盖前 push 的 renderer）
    private var subscribers: [SubscriberEntry] = []

    /// 当前栈顶 renderer（按 token 优先级最高的有效 entry）
    private var topRenderer: (AnyObject & BeautyRenderer)? {
        // 从最高优先级找起；同 token 时后加入的优先（LIFO 语义），符合"call 结束时 pop 回 live"
        subscribers
            .reversed()
            .compactMap { entry -> (SubscriberToken, AnyObject & BeautyRenderer)? in
                guard let r = entry.renderer else { return nil }
                return (entry.token, r)
            }
            .max { $0.0 < $1.0 }?.1
    }

    // MARK: - 中断态（红队 F4）

    /// AVCaptureSession 中断期间 Sharer.apply no-op（Store 变化只写盘不写 SDK）
    @Published private(set) var isInterrupted: Bool = false

    // MARK: - Store 联动 + pending 队列（红队 D1）

    let store: BeautySettingsStore

    /// setup 未 ready 时缓冲 Store 变化的最后一次 settings；ready 后 replay 一次到栈顶
    private var pendingSettings: BeautySettings?

    private var storeCancellable: AnyCancellable?

    // MARK: - init

    /// 生产：`BeautyPipelineSharer.shared` 单例；测试：自建实例注入 Fakes persistence + 触发 setup mock
    init(persistence: BeautySettingsPersistence = UserDefaultsBeautyPersistence()) {
        self.store = BeautySettingsStore(persistence: persistence)
        // 订阅 Store 变化（拖滑块触发）→ 广播到栈顶 renderer or 缓冲到 pending
        storeCancellable = store.$settings
            .dropFirst() // 忽略 init 时的初值发射
            .sink { [weak self] newSettings in
                self?.handleSettingsChanged(newSettings)
            }
    }

    // MARK: - Setup 入口（并发安全）

    /// 触发 setup（幂等）。多 view 并发调用共享同一 Task；已 ready 直接 return。
    ///
    /// 真 setup 由外部（CameraManager 或独立 setup 路径）经 `reportSetupResult(_:)` 通知；
    /// 本方法只管理状态流转，不直接调 FUManager（避免此文件 import FURenderKit，保留 tests 可编）
    func startSetupIfNeeded() {
        switch setupState {
        case .notStarted, .failed:
            setupState = .inProgress
            // 真 setup 走 CameraManager.init → FUManager.setupSync → reportSetupResult 通知回来
            // Step 2 接线时 CameraManager 路径挂入；本 step 1a 只落状态机骨架
        case .inProgress, .ready:
            break // 已在跑 or 已完成
        }
    }

    /// 外部（CameraManager）setup 完成后通知 Sharer 状态迁移。
    /// - Parameter result: `.success` 成功；`.failure(BeautyError)` 降级
    func reportSetupResult(_ result: Result<Void, BeautyError>) {
        switch result {
        case .success:
            setupState = .ready
            // Replay pending 到栈顶（红队 D1）
            if let pending = pendingSettings, let renderer = topRenderer, !isInterrupted {
                renderer.apply(pending)
            }
            pendingSettings = nil
        case .failure(let error):
            setupState = .failed(error)
            logger.warning("Sharer setup failed: \(String(describing: error))")
        }
    }

    // MARK: - Subscriber 管理（Step 2 接线时 view 层调）

    /// 挂载一个 renderer 到栈；返回的 opaque handle 用于 detach。
    /// 同一 renderer 实例多次 attach 用最后一次 token（后写覆盖）。
    func attach(_ renderer: AnyObject & BeautyRenderer, token: SubscriberToken) {
        // 若已存在同实例，先移除旧记录
        subscribers.removeAll { $0.renderer === renderer }
        subscribers.append(SubscriberEntry(renderer: renderer, token: token))
        // 栈顶变化时立即 apply 当前 settings（让新栈顶 renderer 拿到最新参数）
        if let top = topRenderer, top === renderer, !isInterrupted, setupState == .ready {
            renderer.apply(store.settings)
        }
    }

    /// 从栈中移除指定 renderer。
    func detach(_ renderer: AnyObject & BeautyRenderer) {
        subscribers.removeAll { $0.renderer === renderer || $0.renderer == nil }
    }

    /// 清空所有失效引用（weak 已释放的 entry）——防止栈膨胀
    func compactSubscribers() {
        subscribers.removeAll { $0.renderer == nil }
    }

    // MARK: - 中断态（红队 F4，Step 2 接线时 CameraManager 通知）

    func setInterrupted(_ interrupted: Bool) {
        let wasInterrupted = isInterrupted
        isInterrupted = interrupted
        // 中断结束时若有 pending 且 ready，replay
        if wasInterrupted, !interrupted, setupState == .ready {
            if let renderer = topRenderer {
                renderer.apply(store.settings)
            }
        }
    }

    // MARK: - Private: Store 变化路由

    private func handleSettingsChanged(_ settings: BeautySettings) {
        // 中断期间不写 SDK（红队 F4）
        guard !isInterrupted else { return }

        switch setupState {
        case .ready:
            // 广播到栈顶 renderer
            topRenderer?.apply(settings)
        case .notStarted, .inProgress:
            // 缓冲最后一次，ready 后 replay（红队 D1）
            pendingSettings = settings
        case .failed:
            // 降级态：Store 参数照写盘（Store 自身完成）；SDK 不 apply
            break
        }
    }
}

// MARK: - Tests-only 访问

#if DEBUG
extension BeautyPipelineSharer {
    /// 测试用：探测栈顶 renderer（生产不暴露，避免非-Sharer 路径调 apply）
    var testTopRenderer: (AnyObject & BeautyRenderer)? { topRenderer }

    var testSubscriberCount: Int { subscribers.count }

    var testPendingSettings: BeautySettings? { pendingSettings }

    /// 测试用：直接注入 setup 状态跳过真 setup
    func testForceSetupState(_ state: SetupState) { setupState = state }
}
#endif
