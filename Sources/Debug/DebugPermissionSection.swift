#if DEBUG
import SwiftUI

/// DEBUG-only：Settings 页里的权限测试 section。真机 QA 期间快速切换 userType 观察三层 gate 效果。
///
/// **不入 Release 包**（整个文件 `#if DEBUG` 门）。
///
/// **UI 交互**：直接列 7 个 Button rows（对齐 SettingsView `settingsRow` pattern），点击 row 立即切换。
/// **不用 Picker.menu** —— iOS 16 List 里 Picker 默认 `.menu` style 只右侧 chevron 是 tap 区，
/// 左侧 label 文字点不动（SwiftUI 已知陷阱）。改 Button + `.contentShape(Rectangle())` 让整 row 都是热区
/// （对齐 rule swiftui-button-plain-hitarea）。
///
/// 数据源：
/// - `DebugPermissionOverride.shared`：本地注入通道（写入）
/// - `SessionStore.shared.user?.userType`：真实值（对照显示）
/// - `SelfPermissionBridge.shared`：派生权限（观察三层 gate 效果）
struct DebugPermissionSection: View {
    @State private var selection: Preset = .real
    /// SelfPermissionBridge 是单例；观察 @Published 让 canX 变化时 body 重算
    @ObservedObject private var permission = SelfPermissionBridge.shared
    /// SessionStore user 变化时（如切账号）重算 "Real" 显示值
    @ObservedObject private var session = SessionStore.shared

    var body: some View {
        Section("Debug · Permission (userType 注入)") {
            ForEach(Preset.allCases) { preset in
                Button {
                    apply(preset)
                } label: {
                    HStack {
                        Text(preset.label)
                            .foregroundColor(.white)
                            .font(.system(size: 14))
                        Spacer()
                        if selection == preset {
                            Image(systemName: "checkmark")
                                .foregroundColor(.pink)
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            infoRow(title: "Effective", value: effectiveText, mono: true)
            infoRow(title: "canCall / canLive / canParty", value: permissionsText, mono: true)
        }
        .listRowBackground(Theme.Palette.cardFill.opacity(0.6))
        .onAppear { syncSelectionFromOverride() }
    }

    private func apply(_ preset: Preset) {
        selection = preset
        DebugPermissionOverride.shared.override = (preset == .real) ? nil : preset.rawValue
    }

    private func infoRow(title: String, value: String, mono: Bool = false) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.white.opacity(0.8))
                .font(.system(size: 12))
            Spacer()
            Text(value)
                .foregroundColor(.white.opacity(0.6))
                .font(.system(size: 12, design: mono ? .monospaced : .default))
        }
    }

    private var effectiveText: String {
        if let ov = DebugPermissionOverride.shared.override {
            return "\(ov) (override)"
        }
        let real = session.user?.userType.map(String.init) ?? "nil"
        return "\(real) (real)"
    }

    private var permissionsText: String {
        "\(mark(permission.canCall)) / \(mark(permission.canLive)) / \(mark(permission.canParty))"
    }

    private func mark(_ v: Bool) -> String { v ? "✓" : "✗" }

    /// 从 DebugPermissionOverride 反向同步 selection（进入 Settings 时保持一致）
    private func syncSelectionFromOverride() {
        if let ov = DebugPermissionOverride.shared.override,
           let preset = Preset(rawValue: ov) {
            selection = preset
        } else {
            selection = .real
        }
    }

    // MARK: - Preset

    private enum Preset: Int, CaseIterable, Identifiable, Hashable {
        case real = 0
        case v101 = 101
        case v102 = 102
        case v103 = 103
        case v104 = 104
        case v105 = 105
        case v106 = 106

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .real: return "Real (SessionStore)"
            case .v101: return "101 · 屏通话+匹配"
            case .v102: return "102 · 屏直播"
            case .v103: return "103 · 屏 Party"
            case .v104: return "104 · 屏通话+匹配+直播"
            case .v105: return "105 · 屏通话+匹配+Party"
            case .v106: return "106 · 屏直播+Party"
            }
        }
    }
}
#endif
