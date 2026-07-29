import SwiftUI
import AVFoundation

/// Page 2 视频占位卡片（未录 → 灰底 + 摄像机 icon；已录 → 首帧缩略 + 播放 + × 删）
struct VideoSlotView: View {
    @ObservedObject var store: RegisterStore
    let onTap: () -> Void       // 未录时点击 → 弹 VideoGuideSheet

    @State private var previewURL: URL?
    @State private var isShowingPreview = false

    private let cardSize = CGSize(width: 150, height: 200)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.17, green: 0.13, blue: 0.24))
                .frame(width: cardSize.width, height: cardSize.height)
                .overlay {
                    content
                        .frame(width: cardSize.width, height: cardSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onTapGesture {
                    if store.hasVideo {
                        presentPreview()
                    } else {
                        onTap()
                    }
                }

            if store.hasVideo {
                Button {
                    // 清视频状态
                    store.videoUrl = nil
                    store.localVideoOriginalUrl = nil
                    store.localVideoCompressedUrl = nil
                    store.videoCompressProgress = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white)
                        .background(Circle().fill(.black.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .padding(6)
                .zIndex(1)
            }
        }
        .fullScreenCover(isPresented: $isShowingPreview, onDismiss: { previewURL = nil }) {
            if let previewURL {
                VideoPlayerFullScreen(url: previewURL)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        // Finding #12 修：用 store.hasVideo 派生态，与 outer .onTapGesture 判定一致
        if store.hasVideo {
            // 已上传的远端视频提取首帧；本地待上传视频保持黑底占位，避免读取尚未完成写入的文件。
            ZStack {
                if let url = store.videoUrl.flatMap(URL.init(string:)) {
                    VideoThumbnailImage(url: url) {
                        Color.black
                    }
                    .frame(width: cardSize.width, height: cardSize.height)
                    .clipped()
                } else {
                    Color.black
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.85))
            }
        } else if store.isVideoUploading {
            ProgressView().tint(.white)
        } else if let progress = store.videoCompressProgress {
            VStack(spacing: 4) {
                ProgressView(value: progress).tint(.pink)
                Text("Processing... \(Int(progress * 100))%").font(.caption).foregroundStyle(.white)
            }.padding(20)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "video.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.4))
                Text(L10n.Register.fieldTakeVideo)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }.padding(20)
        }
    }

    private func presentPreview() {
        let remoteURL = store.videoUrl.flatMap(URL.init(string:))
        guard let url = remoteURL ?? store.localVideoCompressedUrl ?? store.localVideoOriginalUrl else { return }
        previewURL = url
        isShowingPreview = true
    }
}
