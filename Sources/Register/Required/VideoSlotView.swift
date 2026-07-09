import SwiftUI
import AVFoundation

/// Page 2 视频占位卡片（未录 → 灰底 + 摄像机 icon；已录 → 首帧缩略 + 播放 + × 删）
struct VideoSlotView: View {
    @ObservedObject var store: RegisterStore
    let onTap: () -> Void       // 未录时点击 → 弹 VideoGuideSheet

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.17, green: 0.13, blue: 0.24))
                .frame(width: 150, height: 200)
                .overlay(content)
                .onTapGesture {
                    if store.videoUrl == nil && store.localVideoOriginalUrl == nil {
                        onTap()
                    }
                }

            if store.videoUrl != nil || store.localVideoOriginalUrl != nil {
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
                .padding(6)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.videoUrl != nil || store.localVideoCompressedUrl != nil {
            // 已上传或已压缩 → 显示首帧 + 播放图标
            ZStack {
                Color.black
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
}
