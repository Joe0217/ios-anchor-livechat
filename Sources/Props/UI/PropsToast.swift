import SwiftUI

/// Props 页局部 toast（M1 Step 1b · 简版 overlay · 3s 自动消失）。
///
/// 用途：equip/unequip 前置校验拒绝时反馈（对齐 H5 三条 toast：
/// "You cannot equip this item" / "You already wear this" / "You already unequip this"），
/// 以及 API 失败 "Failed. Try again"。
///
/// 用法：
/// ```swift
/// @State private var toast: String?
/// var body: some View {
///     content.overlay(alignment: .bottom) {
///         if let toast { PropsToastView(message: toast) }
///     }
///     .onChange(of: toast) { _, new in
///         guard new != nil else { return }
///         Task { try? await Task.sleep(nanoseconds: 3_000_000_000); toast = nil }
///     }
/// }
/// ```
struct PropsToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.black.opacity(0.75))
            .clipShape(Capsule())
            .padding(.bottom, 100)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
