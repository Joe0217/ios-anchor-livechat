import SwiftUI
import Combine

/// 全局 toast 中心（对齐 H5 `showNotify(...)` 全局提示模式）。
///
/// **用途**：跨模块 service 层触发用户可感知的成功/失败反馈时用（关注/取关成功、复制成功等）。
/// 传统"每 view 挂 @State toast + overlay"模式对**跨 view 触发**无解 —— service 层不知道当前 view
/// 有没有 overlay，也不该让每个入口 view 都写一套。
///
/// **接入模式**：
/// - Service 层：`await AppToastCenter.shared.show(L10n.commonFollowSuccess)`
/// - 根节点（`RootView`）挂一次 `.appToastOverlay()` modifier，所有场景自动可见
///
/// **视觉复用 [Toast]**：字体 / Capsule / 主色 / topInset 全一致。
///
/// **自动消失**：调 `show` 会 cancel 前次未完成的 dismiss task，避免连续 toast 时前一条被后一条 timer 提前清掉。
@MainActor
final class AppToastCenter: ObservableObject {
    static let shared = AppToastCenter()

    /// 当前 toast（`nil` = 无显示）；view 层 `.overlay` 监听此 published
    @Published fileprivate(set) var message: String?

    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// 显示 toast；若已在显示，立即替换文案 + 重置定时
    func show(_ message: String,
              duration: UInt64 = Toast.dismissDurationNanos) {
        dismissTask?.cancel()
        self.message = message
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: duration)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    /// 立刻清除（不常用；主要用于登出/切换场景时避免残留）
    func dismiss() {
        dismissTask?.cancel()
        message = nil
    }
}

// MARK: - View overlay

private struct AppToastOverlay: ViewModifier {
    @StateObject private var center = AppToastCenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let msg = center.message {
                Text(msg)
                    .toastStyle()
                    .transition(Toast.transition)
                    .zIndex(9999)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.message)
    }
}

extension View {
    /// 挂全局 toast overlay；只在 `RootView` 挂一次即可。
    func appToastOverlay() -> some View {
        modifier(AppToastOverlay())
    }
}
