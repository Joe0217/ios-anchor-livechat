import SwiftUI
import AVKit

/// Page 4 视频预览（对齐 `视频录制5-录制完成.png`）：VideoPlayer + Re-record / Upload
struct RegisterVideoPreviewView: View {
    @EnvironmentObject var store: RegisterStore
    @EnvironmentObject var pathHolder: RegisterPathHolder

    // Bug fix 2026-07-09：AVPlayer 存 @State 稳定引用，避免每次 body re-eval 重建 player 消耗资源 + 加载不同步 crash
    @State private var player: AVPlayer? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                if let player {
                    VideoPlayer(player: player)
                        .frame(maxWidth: .infinity, maxHeight: 500)
                        .cornerRadius(12)
                        .padding(.horizontal, 24)
                } else {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: 500)
                }

                if let p = store.videoCompressProgress, p < 1.0 {
                    VStack(spacing: 4) {
                        ProgressView(value: p).tint(.pink).frame(width: 200)
                        Text("Processing... \(Int(p * 100))%").font(.caption).foregroundStyle(.white)
                    }
                }

                Spacer()

                HStack(spacing: 20) {
                    Button { rerecord() } label: {
                        Text(L10n.Register.actionRerecord)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Color.gray.opacity(0.4), in: Capsule())
                    }
                    Button { Task { await upload() } } label: {
                        HStack(spacing: 8) {
                            if store.isVideoUploading { ProgressView().tint(.white) }
                            Text(L10n.Register.actionUpload).foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            LinearGradient(colors: [.pink, .purple], startPoint: .leading, endPoint: .trailing),
                            in: Capsule()
                        )
                    }
                    .disabled(store.isVideoUploading || (store.videoCompressProgress ?? 0) < 1.0)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 20)
            }
        }
        .navigationBarBackButtonHidden(true)   // Bug fix 2026-07-08：隐藏系统 back，只用自定义 chevron.left
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { pathHolder.path.removeLast() } label: {
                    Image(systemName: "chevron.left").foregroundStyle(.white)
                }
            }
        }
        .onAppear {
            // Bug fix 2026-07-09：view 出现时用当前可用 URL 建 player（优先压缩后，fallback 原始）
            if player == nil, let url = store.localVideoCompressedUrl ?? store.localVideoOriginalUrl {
                player = AVPlayer(url: url)
            }
        }
        .onChange(of: store.localVideoCompressedUrl) { compressedUrl in
            // 压缩完成后切换到压缩版视频（更小画质相近，播放更流畅）
            if let compressedUrl { player = AVPlayer(url: compressedUrl) }
        }
        .onDisappear { player?.pause() }
    }

    private func rerecord() {
        store.localVideoOriginalUrl = nil
        store.localVideoCompressedUrl = nil
        store.videoCompressProgress = nil
        pathHolder.path.removeLast()
    }

    @MainActor
    private func upload() async {
        guard let compressedUrl = store.localVideoCompressedUrl,
              let data = try? Data(contentsOf: compressedUrl) else {
            store.submitError = L10n.Register.errorCompressFailed
            return
        }
        store.isVideoUploading = true
        defer { store.isVideoUploading = false }
        do {
            let ossUrl = try await PublicVideoUploader.shared.upload(videoData: data, fileExtension: "mp4")
            store.videoUrl = ossUrl
            RegisterAnalytics.report(.videoInf)
            // pop 两次回 Required（.videoRecord → .videoPreview 两层）
            pathHolder.path.removeLast(2)
        } catch {
            store.submitError = L10n.Register.errorUploadFailed
        }
    }
}
