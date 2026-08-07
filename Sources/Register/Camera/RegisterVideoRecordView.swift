import SwiftUI

/// Page 3 视频录制页（对齐 `视频录制2.png`）
///
/// 全屏 preview + 顶部倒计时胶囊 20s → 00s + 底部粉色圆按钮
/// 录完自动 push .videoPreview + 后台 Task 触发压缩
struct RegisterVideoRecordView: View {
    @EnvironmentObject var store: RegisterStore
    @EnvironmentObject var pathHolder: RegisterPathHolder
    @StateObject private var recorder = RegisterVideoRecorder()
    @Environment(\.scenePhase) private var scenePhase

    @State private var showBackConfirm = false
    /// Bug fix 2026-07-09：Discard 场景下 recorder.stopRecording() 会 async fire delegate 让 state=.finished，
    /// onChange 触发 append(.videoPreview) 但 path 已 pop → NavigationStack 内部状态错乱 crash。
    /// 用 flag 让 onChange handler 在 discard 后忽略 state 变化
    @State private var isDiscarding = false

    private let maxDuration: TimeInterval = 20

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 2026-07-09 v2：复用直播 CameraPreview（MetalPreviewView 渲染美颜后 CVPixelBuffer）
            // 相较原 RegisterCameraPreview（仅 AVCaptureVideoPreviewLayer 原始画面），本 preview 显示美颜后画面
            CameraPreview(camera: recorder.camera)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                recordButton
                    .padding(.bottom, 60)
            }
        }
        .navigationBarBackButtonHidden(true)
        .task { await recorder.prepare() }
        .onAppear {
            // Bug fix 2026-07-10：用户 Re-record 后 pop 回来，若 recorder 处于 .finished 或 session 被意外停（push preview 触发 onDisappear teardown），
            // 需 restartForRecording 重启 session + 重置 state 到 .ready；否则画面卡死 + tap Record 按钮无反应
            // 首次 appear 时 state 是 .idle，会走 .task prepare()；pop 回来时 state 已经是 .finished，走此分支
            if case .finished = recorder.state {
                Task { await recorder.restartForRecording() }
            }
        }
        .onChange(of: recorder.state) { newState in
            guard !isDiscarding else { return }   // Bug fix 2026-07-09：Discard 后 delegate 仍 fire，忽略避免 pop→append 冲突 crash
            if case .finished(let url) = newState {
                store.localVideoOriginalUrl = url
                store.videoCompressProgress = 0
                pathHolder.path.append(RegisterRoute.videoPreview)
                // Finding #2 修 2026-07-10：压缩 Task capture epoch，完成时判 epoch 不一致（用户 Re-record 递增）→ 忽略结果避免覆盖 store
                let epoch = store.videoCompressEpoch
                Task { @MainActor in
                    do {
                        let compressed = try await RegisterVideoCompressor.compress(sourceUrl: url) { p in
                            guard epoch == store.videoCompressEpoch else { return }   // 旧 Task 的 progress 更新丢弃
                            store.videoCompressProgress = p
                        }
                        guard epoch == store.videoCompressEpoch else { return }        // 旧 Task 完成结果丢弃
                        store.localVideoCompressedUrl = compressed
                        store.videoCompressProgress = 1.0
                    } catch {
                        guard epoch == store.videoCompressEpoch else { return }        // 旧 Task 抛错丢弃
                        store.videoCompressProgress = nil
                        store.submitError = L10n.Register.errorCompressFailed
                    }
                }
            } else if case .failed(let err) = newState {
                // 录制中断/权限拒 → toast + pop
                store.submitError = err == .cameraDenied ? L10n.Register.errorCameraDenied
                    : err == .microphoneDenied ? L10n.Register.errorMicDenied
                    : L10n.Register.errorRecordInterrupted
                // Finding #6 修：guard path 非空
                if !pathHolder.path.isEmpty { pathHolder.path.removeLast() }
            }
        }
        .onDisappear {
            // spec v3 MAJOR-3：切后台不 tearDown（会破坏 preview 恢复）；仅真正离开页面才清
            guard scenePhase != .background else { return }
            // Bug fix 2026-07-11：改 suspend 替代 teardown。teardown → camera.tearDown() → subscribers.removeAll()
            // 会清掉 CameraPreview 的 subscribe，Re-record pop 回来时 SwiftUI 不保证 updateUIView fire
            // → Coordinator 无法 re-attach → 画面卡最后一帧（rule swiftui-camera-preview §3）
            // suspend 只 stop session 保留 subscribers；真最终清理由 @StateObject deinit → camera.tearDown() 触发
            recorder.suspend()
        }
        .alert(L10n.Register.videoDiscardConfirm, isPresented: $showBackConfirm) {
            Button(L10n.commonDiscard, role: .destructive) {
                isDiscarding = true       // 立即 set 防 onChange 尝试 push preview
                recorder.stopRecording()
                // Finding #6 修：guard path 非空
                if !pathHolder.path.isEmpty { pathHolder.path.removeLast() }
            }
            Button(L10n.Register.actionCancel, role: .cancel) {}
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                // Finding #6 修 2026-07-10：guard path 非空
                guard !pathHolder.path.isEmpty else { return }
                handleBackTap()
            } label: {
                Image(systemName: "chevron.left")
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Circle().fill(.black.opacity(0.4)))
            }
            .padding(.leading, 16)

            Spacer()

            timerCapsule
                .padding(.trailing, 50)

            Spacer()
        }
        .padding(.top, 44)
    }

    private var timerCapsule: some View {
        let remaining: Int = {
            if case .recording(let elapsed) = recorder.state {
                return max(0, Int((maxDuration - elapsed).rounded(.up)))
            }
            return Int(maxDuration)
        }()
        let mm = String(format: "%02d", remaining / 60)
        let ss = String(format: "%02d", remaining % 60)
        return Text("00:\(ss)")
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(
                LinearGradient(colors: [.pink, .purple], startPoint: .leading, endPoint: .trailing),
                in: Capsule()
            )
    }

    private var recordButton: some View {
        Button {
            if case .ready = recorder.state {
                recorder.startRecording()
            }
        } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 3).frame(width: 82, height: 82)
                Circle()
                    .fill(LinearGradient(colors: [.pink, .purple], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 68, height: 68)
                if case .recording = recorder.state {
                    RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 16, height: 16)
                }
            }
        }
        .disabled(recorder.state != .ready && !(recorder.state == .recording(elapsed: recorder.elapsed)))
    }

    private func handleBackTap() {
        if case .recording = recorder.state {
            showBackConfirm = true
        } else {
            guard !pathHolder.path.isEmpty else { return }
            pathHolder.path.removeLast()
        }
    }
}
