import SwiftUI
import AVKit

/// Page 4 视频预览（对齐 `视频录制5-录制完成.png`）：VideoPlayer + Re-record / Upload
struct RegisterVideoPreviewView: View {
    @EnvironmentObject var store: RegisterStore
    @EnvironmentObject var pathHolder: RegisterPathHolder

    // Bug fix 2026-07-09：AVPlayer 存 @State 稳定引用,避免每次 body re-eval 重建 player 消耗资源 + 加载不同步 crash
    @State private var player: AVPlayer? = nil
    /// 2026-07-14 review finding P0 修:preview 页 upload/compress fail 时 store.submitError 被 set 但无展示,
    /// 因用户还站在 preview 页(RequiredView 底层 onChange 拿不到).加本地 toast 与 RequiredView 一致的展示交互
    @State private var toastMsg: String? = nil

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

            // 2026-07-14 review finding P0 修:preview 页本地 toast(与 RequiredView 一致的展示)
            if let msg = toastMsg {
                VStack {
                    Text(msg).font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(
                            LinearGradient(colors: [.pink, .purple], startPoint: .leading, endPoint: .trailing),
                            in: Capsule()
                        )
                        .padding(.top, 100)
                    Spacer()
                }
            }
        }
        .onChange(of: store.submitError) { err in
            // 2026-07-14 review finding P0 修:preview 页 upload/compress fail 时展示 toast(否则用户只见 button spinner 停但无错误提示)
            if let err {
                showToast(err)
                store.submitError = nil
            }
        }
        .navigationBarBackButtonHidden(true)   // Bug fix 2026-07-08：隐藏系统 back，只用自定义 chevron.left；副作用禁左滑（2026-07-11 用户明示注册所有页禁左滑关闭）
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    // Finding #6 修 2026-07-10：guard path 非空，避免 logout/reset 后 tap back 触发 NavigationPath precondition crash
                    guard !pathHolder.path.isEmpty else { return }
                    pathHolder.path.removeLast()
                } label: {
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
            // Finding #11 修 2026-07-10：用 replaceCurrentItem 保 player 上下文（复用 decoder / 播放位置/暂停态），
            // 避免整个新 AVPlayer 替换让旧 player deinit + 黑帧闪烁
            if let compressedUrl {
                if let existing = player {
                    existing.replaceCurrentItem(with: AVPlayerItem(url: compressedUrl))
                } else {
                    player = AVPlayer(url: compressedUrl)
                }
            }
        }
        .onDisappear { player?.pause() }
    }

    private func rerecord() {
        store.localVideoOriginalUrl = nil
        store.localVideoCompressedUrl = nil
        store.videoCompressProgress = nil
        // Finding #2 修 2026-07-10：递增 epoch 让旧压缩 Task 完成时 guard 判 stale 丢弃结果
        store.videoCompressEpoch += 1
        // Finding #6 修 2026-07-10：guard path 非空
        guard !pathHolder.path.isEmpty else { return }
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
            // Finding #6 修 2026-07-10：guard path 层数 ≥2 避免 logout/reset 后 upload 完成触发 precondition crash
            let popCount = min(2, pathHolder.path.count)
            if popCount > 0 { pathHolder.path.removeLast(popCount) }
        } catch {
            store.submitError = L10n.Register.errorUploadFailed
        }
    }

    private func showToast(_ msg: String) {
        toastMsg = msg
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            toastMsg = nil
        }
    }
}
