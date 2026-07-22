import SwiftUI

/// 全 app **toast 视觉单一来源**。所有样式 token 集中在 `Toast` 枚举里，改主题只改本文件。
///
/// **样式规范**：
/// - 背景：`Capsule` 胶囊 · 主按钮渐变中间色 `0xB4245C` @ 80% opacity
///   （ChatPalette.primaryGradient `0x8515FF → 0xE40132` 的均值，保证 toast 与 CTA 主视觉同调）
/// - 字体：13pt semibold 白色
/// - 内边距：14 水平 × 8 垂直
/// - 距顶部：默认 100pt（≈ iPhone 屏高 12%，避开 nav bar + Party 创房参考位下移 10%）
/// - 自动消失：2s（call site 用 `Toast.dismissDurationNanos` 保持一致）
/// - 过渡动画：从顶部滑入 + 淡入淡出（`Toast.transition`）
///
/// **使用**（call site 只保留业务态判断 + 生命周期，视觉全走本 modifier）：
/// ```swift
/// .overlay(alignment: .top) {
///     if let msg = store.toast {
///         Text(msg)
///             .toastStyle()
///             .transition(Toast.transition)
///             .task(id: msg) {
///                 try? await Task.sleep(nanoseconds: Toast.dismissDurationNanos)
///                 store.clearToast()
///             }
///     }
/// }
/// ```
enum Toast {

    // MARK: - Visual tokens（改样式改这里）

    /// 背景底色（主按钮渐变中间色 0xB4245C，与 Chat 页 CTA 同调）
    static let backgroundColor = Color(hex: 0xB4245C)
    /// 背景透明度
    static let backgroundOpacity: Double = 0.8
    /// 文字色
    static let textColor = Color.white
    /// 文字字体
    static let textFont: Font = .system(size: 13, weight: .semibold)

    // MARK: - Layout tokens

    /// 水平内边距
    static let horizontalPadding: CGFloat = 14
    /// 垂直内边距
    static let verticalPadding: CGFloat = 8
    /// 距顶部偏移（≈ iPhone 屏高 22%，Party 创房参考位 60 → 100 → 180 累计下移 ~20%）—— sheet 内 toast 可传自定义值覆盖
    static let topInset: CGFloat = 180

    // MARK: - Behavior tokens

    /// 过渡动画（顶部滑入 + 淡入淡出）
    static let transition: AnyTransition = .move(edge: .top).combined(with: .opacity)
    /// 自动消失时长（秒）—— 常规提示（info / 短暂错误）
    static let dismissDuration: TimeInterval = 2.0
    /// 自动消失时长（纳秒），供 `Task.sleep(nanoseconds:)` 直接使用
    static let dismissDurationNanos: UInt64 = 2_000_000_000
    /// 长时长（秒）—— 需更长阅读时间的严重错误提示（Party 创房失败 / 房间设置保存失败 / 管理员管理失败）
    static let dismissDurationLong: TimeInterval = 3.0
    /// 长时长（纳秒）
    static let dismissDurationLongNanos: UInt64 = 3_000_000_000
}

extension View {
    /// 统一 toast 视觉：Capsule + 主按钮色 80% + 白粗体 + 距顶 100pt。
    /// - Parameter topInset: 距顶部偏移。默认 `Toast.topInset`；sheet 内 toast 可传自定义值。
    func toastStyle(topInset: CGFloat = Toast.topInset) -> some View {
        self
            .font(Toast.textFont)
            .foregroundColor(Toast.textColor)
            .padding(.horizontal, Toast.horizontalPadding)
            .padding(.vertical, Toast.verticalPadding)
            .background(Capsule().fill(Toast.backgroundColor.opacity(Toast.backgroundOpacity)))
            .padding(.top, topInset)
    }
}
