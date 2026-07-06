import Combine
import Foundation
import UIKit

/// L 里程碑：匹配态独立摄像头会话（`MatchCameraSessionProtocol` 具体实现）。
///
/// **实现原则**（对齐现有 6 处 CameraManager 挂载模式，见 CallView / LiveRoomView / LivePrepareView 等）：
/// - 内部封装**独立** `CameraManager()` 实例（**非** App 全局共享 session）
/// - 生命周期 = MatchCameraSession 生命周期（MatchTabView `@StateObject` 持有）
/// - 命中接通"移交"= MatchCameraSession.stop() → CallView 自建 CameraManager 独立启动
///   （视觉上短暂 300-500ms 空档，掩盖在 g-waitingCall 过渡）
///
/// **对外接口**：
/// - 属性：`camera: CameraManager`（暴露给 UI 层做 `CameraPreview(camera:)`）
/// - protocol：start/stop/subscribe/publishers（供 MatchStore 观察）
@MainActor
final class MatchCameraSession: MatchCameraSessionProtocol, ObservableObject {

    /// 内部独立 CameraManager 实例（对外只读，UI 用于 `CameraPreview(camera:)`）
    let camera = CameraManager()

    // MARK: - Protocol 属性

    var isRunning: Bool { camera.session.isRunning }

    @Published private(set) var interruptionUnrecoveredDuration: TimeInterval = 0

    // MARK: - Publishers（PassthroughSubject 广播事件）

    private let timedOutSubject = PassthroughSubject<Void, Never>()
    private let errorSubject = PassthroughSubject<MatchCameraError, Never>()

    var timedOutPublisher: AnyPublisher<Void, Never> {
        timedOutSubject.eraseToAnyPublisher()
    }

    var errorPublisher: AnyPublisher<MatchCameraError, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    // MARK: - 内部订阅

    private var cancellables = Set<AnyCancellable>()
    /// 是否已 fire timedOut（防止 30s 后每秒重复 fire）
    private var didFireTimedOut = false

    // MARK: - init / deinit

    init() {
        // 订阅 CameraManager.$interruptionUnrecoveredDuration → 转发 + 30s 一次性触发 timedOut
        camera.$interruptionUnrecoveredDuration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                guard let self else { return }
                self.interruptionUnrecoveredDuration = duration
                if duration == 0 {
                    // interruption 已恢复（handleInterruptionEnded 归零）→ 重置 fire flag
                    self.didFireTimedOut = false
                } else if duration >= 30 && !self.didFireTimedOut {
                    self.didFireTimedOut = true
                    self.timedOutSubject.send()
                }
            }
            .store(in: &cancellables)

        // 转发 CameraManager.onError → errorPublisher
        camera.onError = { [weak self] err in
            guard let self else { return }
            let matchErr: MatchCameraError = {
                switch err {
                case .permissionDenied:                    return .permissionDenied
                case .sessionRuntimeError(let desc):       return .runtimeError(desc)
                case .wasInterrupted(let raw):             return .runtimeError("interrupted reason=\(raw)")
                case .interruptionEnded:                   return .runtimeError("interruptionEnded")
                }
            }()
            Task { @MainActor [weak self] in
                self?.errorSubject.send(matchErr)
            }
        }
    }

    deinit {
        // camera 由 `let` 强持有，随 self 释放；不显式 tearDown 以避免 MainActor 隔离问题
        // （tearDown 需 MainActor，deinit 可能在其他线程调用）
    }

    // MARK: - Protocol 方法

    func start() {
        // 权限门控 + 3s 开启超时（R6：>3s 未 running → error）
        CameraManager.requestAccess { [weak self] granted in
            guard let self else { return }
            if granted {
                self.camera.start()
                self.startStartupTimeoutGuard()
            } else {
                self.errorSubject.send(.permissionDenied)
            }
        }
    }

    func stop() {
        camera.tearDown()
    }

    // MARK: - 3s 启动超时守卫

    private func startStartupTimeoutGuard() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            if !self.camera.session.isRunning {
                self.errorSubject.send(.startTimeout)
            }
        }
    }
}
