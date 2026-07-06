import SwiftUI

/// L 里程碑 Match：匹配态摄像头预览浮窗（拖动 + 关闭按钮）。
///
/// **交互**：
/// - **拖动**：全屏范围内随意拖动，DragGesture 累计 offset；释放后 clamp 到 container 内不出界
/// - **关闭按钮**（右上角 xmark）：点击 → 调 `onClose` closure（生产用于走 closeMatch，
///   避免"关 UI 但摄像头继续 running"的状态不一致）
///
/// **父视图布局要点**：本 View 用 `.position()` 定位（相对 GeometryReader container），
/// 父需给 container 明确大小（本 View 默认放到 `.overlay(alignment: .bottomTrailing)` 内不适用；
/// 直接 overlay 到 tab 内容层，使用 GeometryReader 拿全屏尺寸）
struct MatchCameraPreviewFloating: View {
    let camera: CameraManager
    let onClose: () -> Void

    /// 浮窗尺寸
    private let width: CGFloat = 120
    private let height: CGFloat = 160
    /// 初始 inset（右下角，避开底部 CGoMatchButton + tabbar）
    private let initialTrailingInset: CGFloat = 12
    private let initialBottomInset: CGFloat = Theme.Metric.matchButtonBottomInset
        + Theme.Metric.matchButtonSize + 8

    /// 累计位置（相对 container，用 CGPoint 表 view 中心）；nil 表使用初始位置
    @State private var position: CGPoint?
    /// 拖动过程中的偏移（onChanged 累计，onEnded 归零并合并到 position）
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let center = currentCenter(in: geo.size)
            preview
                .position(x: center.x + dragOffset.width,
                          y: center.y + dragOffset.height)
                .gesture(dragGesture(in: geo.size))
        }
    }

    // MARK: - 预览本体 + 关闭按钮

    private var preview: some View {
        ZStack(alignment: .topTrailing) {
            CameraPreview(camera: camera)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.Palette.matchMarqueeBorderStart, lineWidth: 1.5)
                )

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .padding(6)
            .accessibilityLabel(L10n.matchButtonA11yTurnOff)
        }
        .frame(width: width, height: height)
        .accessibilityElement(children: .contain)
    }

    // MARK: - 拖动手势

    private func dragGesture(in containerSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                // 拖动结束：合并 translation 到 position 并 clamp
                let current = currentCenter(in: containerSize)
                let newCenter = CGPoint(
                    x: current.x + value.translation.width,
                    y: current.y + value.translation.height
                )
                position = clamp(center: newCenter, in: containerSize)
                dragOffset = .zero
            }
    }

    /// 当前 center（相对 container）：优先 @State position；否则用初始 inset 计算
    private func currentCenter(in size: CGSize) -> CGPoint {
        if let p = position { return p }
        return CGPoint(
            x: size.width - initialTrailingInset - width / 2,
            y: size.height - initialBottomInset - height / 2
        )
    }

    /// 限制 center 使浮窗不出 container 边界
    private func clamp(center: CGPoint, in size: CGSize) -> CGPoint {
        let minX = width / 2
        let maxX = size.width - width / 2
        let minY = height / 2
        let maxY = size.height - height / 2
        return CGPoint(
            x: min(max(center.x, minX), maxX),
            y: min(max(center.y, minY), maxY)
        )
    }
}
