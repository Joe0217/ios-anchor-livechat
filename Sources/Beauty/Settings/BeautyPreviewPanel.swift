import SwiftUI

/// K spec §3.3：顶部预览区 + 状态横幅（loading / unavailable / interrupted）。
///
/// - 复用 `CameraPreview`（`.claude/rules/swiftui-camera-preview.md` §3 订阅字典）
/// - **Passthrough 兜底不黑屏**（红队 D1）：Sharer 未 ready 时相机仍能显示原始画面
/// - 横幅样式：半透明胶囊条 + 图标 + 文案，避免全屏遮罩（`.claude/rules/swiftui-camera-preview.md` §8）
struct BeautyPreviewPanel: View {
    @ObservedObject var camera: CameraManager
    @ObservedObject var sharer: BeautyPipelineSharer

    var body: some View {
        ZStack(alignment: .top) {
            // 相机预览（Sharer 未 ready 时走 PassthroughRenderer，画面仍可见）
            CameraPreview(camera: camera)
                .clipped()
                .accessibilityLabel(L10n.BeautySettings.a11yPreview)

            // 状态横幅（叠加在预览顶部）
            statusBanner
                .padding(.horizontal, 12)
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch sharer.setupState {
        case .notStarted, .inProgress:
            bannerCapsule(icon: "hourglass",
                          text: L10n.BeautySettings.bannerLoading,
                          bgOpacity: 0.6)
        case .failed:
            bannerCapsule(icon: "exclamationmark.triangle.fill",
                          text: L10n.BeautySettings.bannerUnavailable,
                          bgOpacity: 0.7)
        case .ready:
            if sharer.isInterrupted {
                bannerCapsule(icon: "pause.circle.fill",
                              text: L10n.BeautySettings.bannerInterrupted,
                              bgOpacity: 0.6)
            } else {
                EmptyView()
            }
        }
    }

    private func bannerCapsule(icon: String, text: String, bgOpacity: Double) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
            Text(text)
                .font(Theme.Typography.caption)
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(bgOpacity), in: Capsule())
    }
}

// Preview 层不能真跑 CameraManager（相机权限 + FUManager.setupSync），仅示意状态横幅样式
private struct BeautyPreviewPanelStubbed: View {
    let stateLabel: String
    let icon: String
    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Color.gray.opacity(0.4))
                .overlay(Text("Camera Preview 占位").foregroundStyle(.white))
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12))
                Text(stateLabel).font(Theme.Typography.caption)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.black.opacity(0.6), in: Capsule())
            .padding(.top, 8)
        }
        .frame(height: 220)
    }
}

#Preview("Banner - Loading") {
    BeautyPreviewPanelStubbed(stateLabel: L10n.BeautySettings.bannerLoading, icon: "hourglass")
}

#Preview("Banner - Unavailable") {
    BeautyPreviewPanelStubbed(stateLabel: L10n.BeautySettings.bannerUnavailable, icon: "exclamationmark.triangle.fill")
}

#Preview("Banner - Interrupted") {
    BeautyPreviewPanelStubbed(stateLabel: L10n.BeautySettings.bannerInterrupted, icon: "pause.circle.fill")
}
