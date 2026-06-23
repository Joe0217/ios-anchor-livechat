import SwiftUI
import AVKit

/// Profile 相册 / 视频全屏预览。
///
/// 图片：远端图 + 双击缩放 + Pinch 缩放 + 拖移；
/// 视频：AVKit VideoPlayer 自动播放；
/// 顶部 X 按钮关闭，整页黑底。
struct MediaPreviewView: View {
    let item: MediaAsset
    let isVideo: Bool
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isVideo {
                videoPlayer
            } else {
                imagePreview
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.black.opacity(0.5), in: Circle())
                    }
                    .accessibilityLabel(L10n.mediaPreviewClose)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var videoPlayer: some View {
        if let urlString = item.url, let url = URL(string: urlString) {
            VideoPlayer(player: AVPlayer(url: url))
                .ignoresSafeArea()
        } else {
            placeholderText
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let urlString = item.url, let url = URL(string: urlString) {
            ZoomableAsyncImage(url: url)
        } else {
            placeholderText
        }
    }

    private var placeholderText: some View {
        Text("URL unavailable")
            .font(.system(size: 14))
            .foregroundColor(.white.opacity(0.6))
    }
}

/// 可缩放/拖移的 AsyncImage：MagnificationGesture + DragGesture 组合，
/// 双击在 1x 与 2x 之间切换；最大 4x；松手平滑回到边界。
private struct ZoomableAsyncImage: View {
    let url: URL

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img):
                img.resizable().scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(magnification)
                    .simultaneousGesture(drag)
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if scale > 1 {
                                scale = 1
                                offset = .zero
                            } else {
                                scale = 2
                            }
                            lastScale = scale
                            lastOffset = offset
                        }
                    }
            case .empty:
                ProgressView().tint(.white)
            case .failure:
                VStack(spacing: 8) {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("Failed to load")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.6))
                }
            @unknown default:
                EmptyView()
            }
        }
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(lastScale * value, 1), 4)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }
}
