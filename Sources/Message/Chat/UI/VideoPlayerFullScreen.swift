import AVKit
import SwiftUI

/// 视频全屏播放器（H-2 spec §5.1 P13，tap 视频气泡触发）。
///
/// **实现**：SwiftUI `VideoPlayer` 包 AVPlayer；顶部返回按钮 dismiss。
/// **性能**：AVPlayer 天然流媒体（HTTP 分片下载），不预 buffer 整段。
struct VideoPlayerFullScreen: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.4), in: Circle())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.mediaPreviewClose)
            .padding(.top, 12)
            .padding(.leading, 12)
        }
        .task {
            player = AVPlayer(url: url)
        }
    }
}
