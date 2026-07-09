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
            .padding(.top, 12)
            .padding(.leading, 12)
        }
        .task {
            player = AVPlayer(url: url)
        }
    }
}

/// 图片全屏预览（H-2 spec §5.1 P13 图片路径）。
///
/// **交互**：pinch 缩放 + drag 平移 + tap 关闭（下拉手势由 sheet 自身负责）。
struct FullScreenImagePreview: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(zoomGesture)
                        .simultaneousGesture(panGesture)
                case .failure:
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.4))
                default:
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture { dismiss() }

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
            .padding(.top, 12)
            .padding(.leading, 12)
        }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale = max(1.0, min(4.0, $0)) }
            .onEnded { _ in
                if scale < 1.05 {
                    withAnimation { scale = 1.0; offset = .zero }
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { offset = $0.translation }
            .onEnded { _ in
                if scale < 1.05 {
                    withAnimation { offset = .zero }
                }
            }
    }
}
