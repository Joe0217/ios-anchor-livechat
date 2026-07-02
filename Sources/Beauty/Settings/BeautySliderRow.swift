import SwiftUI

/// K spec §3.3：单参数滑块行。
///
/// 关键约束：
/// - **Slider 锁 LTR**（红队 B3）：`.environment(\.layoutDirection, .leftToRight)`
///   业务语义"值 40"与 UI 方向无关，ar RTL locale 下拖到视觉右端仍应写 100
/// - value binding 走 Store.mutate 让 dirty 状态生效
/// - enabled=false 时禁用交互 + 灰度显示
struct BeautySliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// 显示值取整（默认 true）；type2 参数也用 Int 显示但范围含负数
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(enabled ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                Spacer()
                Text("\(Int(value.rounded()))")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range)
                .tint(Theme.Palette.brandPink)
                .environment(\.layoutDirection, .leftToRight)  // 红队 B3
                .disabled(!enabled)
                .accessibilityLabel(String(format: L10n.BeautySettings.a11ySliderFormat,
                                           label, Int(value.rounded())))
        }
    }
}

private struct BeautySliderRowPreviewWrapper: View {
    @State var enabledValue: Double = 55
    @State var negValue: Double = -20
    var body: some View {
        VStack(spacing: 20) {
            BeautySliderRow(label: L10n.BeautySettings.paramBlur,
                            value: $enabledValue, range: 0...100, enabled: true)
            BeautySliderRow(label: L10n.BeautySettings.paramIntensityChin,
                            value: $negValue, range: -50...50, enabled: true)
            BeautySliderRow(label: L10n.BeautySettings.paramWhiten,
                            value: .constant(40), range: 0...100, enabled: false)
        }
        .padding()
        .background(Theme.Palette.screenBackground)
    }
}

#Preview("BeautySliderRow 状态") {
    BeautySliderRowPreviewWrapper()
}
