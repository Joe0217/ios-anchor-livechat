import SwiftUI

/// K spec H5 对齐版（2026-07-02）：参数图标横滑行 + Recover 首位。
///
/// 交互（对齐 H5 beautySettings 截图）：
/// - 首位：Recover（`arrow.counterclockwise`），点击重置本组所有参数到 defaults
/// - 其余：每个参数一个圆形 icon + 下方 label；点击 selectedParam 切换到该 param
/// - 选中态：粉色描边圆 + 图标粉色 + label 粉色加粗
/// - 未选中态：紫灰描边圆 + 图标白色 60%
struct BeautyParamIconRow: View {
    let params: [BeautyParamEntry]
    @Binding var selectedParamId: String?
    /// Recover 点击 → 父 view 决定重置本组还是全体
    let onRecover: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 18) {
                recoverCell
                ForEach(params) { param in
                    paramCell(param)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Recover 首位

    private var recoverCell: some View {
        Button {
            onRecover()
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .stroke(Color.white.opacity(0.35), lineWidth: 1.2)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.white.opacity(0.85))
                    )
                Text(L10n.BeautySettings.recover)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 54)
            .contentShape(Rectangle())  // 热区覆盖全 cell
        }
        .buttonStyle(.plain)
    }

    // MARK: - 参数 cell

    private func paramCell(_ p: BeautyParamEntry) -> some View {
        let selected = selectedParamId == p.id
        let iconColor = selected ? Theme.Palette.brandPinkA : Color.white.opacity(0.85)
        return Button {
            selectedParamId = p.id
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .stroke(selected ? Theme.Palette.brandPinkA : Color.white.opacity(0.35),
                            lineWidth: selected ? 2 : 1.2)
                    .frame(width: 44, height: 44)
                    .overlay(paramIcon(p, color: iconColor))
                Text(p.label)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.Palette.brandPinkA : Color.white.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 54)
            .contentShape(Rectangle())  // 热区覆盖全 cell
        }
        .buttonStyle(.plain)
    }

    /// 分派渲染 asset image（H5 官方 Mob 图标）vs SF Symbol（iOS 独有的 4 项 shape 参数兜底）。
    /// asset 走 `.renderingMode(.template)` + `.foregroundStyle` 让 png 跟随选中态染色（与 SF Symbol 视觉一致）。
    @ViewBuilder
    private func paramIcon(_ p: BeautyParamEntry, color: Color) -> some View {
        if p.isAssetIcon {
            Image(p.icon)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .foregroundStyle(color)
        } else {
            Image(systemName: p.icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
        }
    }
}

private struct BeautyParamIconRowPreviewWrapper: View {
    @State var selectedId: String? = "blur"
    var body: some View {
        BeautyParamIconRow(
            params: BeautyParamCatalog.skinParams,
            selectedParamId: $selectedId,
            onRecover: {}
        )
        .background(Color(hex: 0x2D1B4E))
    }
}

#Preview("Skin 参数行") {
    BeautyParamIconRowPreviewWrapper()
}
