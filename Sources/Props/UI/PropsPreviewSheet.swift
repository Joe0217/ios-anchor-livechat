import SwiftUI
import AVKit

/// Props 预览弹窗（M1 Step 1b · spec §4.3）· 对齐 H5 `virtualPropsPreview.vue` 三分支。
///
/// **分支判定**（对齐 H5 URL `.lowercased().contains(...)`，兼容 signed query string）：
/// - itemType == .entrance → 占位文案 "Entrance Preview"
/// - URL 含 `.svga` → RemoteSVGAImageView（loops=0 无限循环 · 复用项目通用组件）
/// - URL 含 `.mp4` / `.webm` → AVKit VideoPlayer（**M1 简版**：无 alpha 通道 · 用户能看到动效）
///   - Note：完整的 alpha 通道预览需 YYEva 直调，工作量大，延后到独立里程碑
/// - 其他 → CachedAsyncImage 静态图
struct PropsPreviewSheet: View {
    let item: PropItem
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()

            content
                .frame(maxWidth: 340, maxHeight: 340)

            // 右上关闭 X
            VStack {
                HStack {
                    Spacer()
                    Button(action: closeAction) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .interactiveDismissDisabled(false)
    }

    @ViewBuilder private var content: some View {
        if item.itemType == .entrance {
            // Entrance 类型占位（对齐 H5 line 43-45）
            Text("Entrance Preview")
                .font(.system(size: 18))
                .foregroundStyle(.gray)
        } else if item.isSVGAResource {
            RemoteSVGAImageView(url: URL(string: item.itemImg),
                                loops: 0,
                                contentMode: .scaleAspectFit)
        } else if item.isMP4Resource {
            // M1 简版：AVKit 播 mp4（无 alpha 通道 · 完整版 YYEva 独立里程碑）
            if let url = URL(string: item.itemImg) {
                VideoPlayer(player: makeLoopedPlayer(url: url))
                    .aspectRatio(1, contentMode: .fit)
            } else {
                fallbackImage
            }
        } else {
            fallbackImage
        }
    }

    @ViewBuilder private var fallbackImage: some View {
        CachedAsyncImage(url: URL(string: item.itemImg),
                         contentMode: .fit,
                         persistent: true) {
            ProgressView().tint(.white)
        }
    }

    // MARK: - AVPlayer looped

    /// 循环播放 mp4（简版）· 播完自动 seek 0 复播
    @MainActor
    private func makeLoopedPlayer(url: URL) -> AVPlayer {
        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .none
        player.isMuted = false
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }
        player.play()
        return player
    }

    private func closeAction() {
        onClose()
        dismiss()
    }
}
