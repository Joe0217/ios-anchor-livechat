import AVFoundation
import CoreImage
import ImageIO
import SwiftUI
import UIKit
import Vision

/// Active liveness for withdrawal. It deliberately mirrors the H5 challenge
/// sequence (head turn, nod, frontal hold) and delegates identity comparison to
/// the existing server endpoint after an OSS upload.
struct FaceLivenessView: View {
    let verifyJPEG: (Data) async throws -> Void
    let onSucceeded: () -> Void
    let onCancelled: () -> Void

    @StateObject private var model: FaceLivenessViewModel

    init(
        verifyJPEG: @escaping (Data) async throws -> Void,
        onSucceeded: @escaping () -> Void,
        onCancelled: @escaping () -> Void
    ) {
        self.verifyJPEG = verifyJPEG
        self.onSucceeded = onSucceeded
        self.onCancelled = onCancelled
        _model = StateObject(wrappedValue: FaceLivenessViewModel(verifyJPEG: verifyJPEG))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            FaceLivenessPreview(camera: model.camera)
                .ignoresSafeArea()

            Color.black.opacity(0.28).ignoresSafeArea()

            VStack(spacing: 18) {
                HStack {
                    Button {
                        cancelLiveness()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.32), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isSubmitting)
                    .accessibilityLabel(L10n.commonClose)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)

                Spacer()

                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.45), lineWidth: 3)
                        .frame(width: 244, height: 244)
                    Circle()
                        .trim(from: 0, to: model.progress)
                        .stroke(Theme.Palette.partyCreateBtnA, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 244, height: 244)
                }
                .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(model.title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(model.detail)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 310)
                }

                if model.isSubmitting {
                    ProgressView()
                        .tint(.white)
                        .padding(.top, 8)
                }

                Spacer()
                    .frame(height: 90)
            }
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
        .alert(L10n.Wallet.livenessFailedTitle, isPresented: $model.showsFailure) {
            Button(L10n.Wallet.retry) {
                AnalyticsTracker.track("h_real_ppl_confirm_click", properties: ["result": "confirm"])
                Task { await model.restart() }
            }
            Button(L10n.commonClose, role: .cancel) {
                cancelLiveness()
            }
        } message: {
            Text(model.failureMessage)
        }
        .onChange(of: model.didSucceed) { succeeded in
            guard succeeded else { return }
            onSucceeded()
        }
    }

    private func cancelLiveness() {
        AnalyticsTracker.track("h_real_ppl_confirm_click", properties: ["result": "cancel"])
        model.cancel()
        onCancelled()
    }
}

@MainActor
final class FaceLivenessViewModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case shake
        case nod
        case front

        var title: String {
            switch self {
            case .shake: return L10n.Wallet.livenessShakeTitle
            case .nod: return L10n.Wallet.livenessNodTitle
            case .front: return L10n.Wallet.livenessFrontTitle
            }
        }

        var detail: String {
            switch self {
            case .shake: return L10n.Wallet.livenessShakeDetail
            case .nod: return L10n.Wallet.livenessNodDetail
            case .front: return L10n.Wallet.livenessFrontDetail
            }
        }
    }

    let camera = FaceLivenessCameraController()

    @Published private(set) var step: Step = .shake
    @Published private(set) var isSubmitting = false
    @Published var showsFailure = false
    @Published private(set) var failureMessage = ""
    @Published private(set) var didSucceed = false

    private let verifyJPEG: (Data) async throws -> Void
    private var deadlineTask: Task<Void, Never>?
    private var noFaceFrames = 0
    private var shakeDirection: Int?
    private var nodDirection: Int?
    private var frontFrames = 0
    private var isStopped = false

    init(verifyJPEG: @escaping (Data) async throws -> Void) {
        self.verifyJPEG = verifyJPEG
        camera.onObservation = { [weak self] observation in
            Task { @MainActor in self?.consume(observation) }
        }
        camera.onFailure = { [weak self] in
            Task { @MainActor in self?.fail(message: L10n.Wallet.livenessCameraUnavailable) }
        }
    }

    var progress: CGFloat { CGFloat(step.rawValue) / CGFloat(Step.allCases.count) }
    var title: String { isSubmitting ? L10n.Wallet.livenessVerifying : step.title }
    var detail: String { isSubmitting ? L10n.Wallet.livenessVerifyingDetail : step.detail }

    func start() async {
        guard !isStopped else { return }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let permitted: Bool
        switch status {
        case .authorized:
            permitted = true
        case .notDetermined:
            permitted = await AVCaptureDevice.requestAccess(for: .video)
        default:
            permitted = false
        }
        guard permitted else {
            fail(message: L10n.Wallet.cameraPermissionRequired)
            return
        }
        camera.start()
        scheduleDeadline()
    }

    func restart() async {
        guard !isSubmitting else { return }
        deadlineTask?.cancel()
        showsFailure = false
        failureMessage = ""
        didSucceed = false
        step = .shake
        noFaceFrames = 0
        shakeDirection = nil
        nodDirection = nil
        frontFrames = 0
        isStopped = false
        camera.start()
        scheduleDeadline()
    }

    func stop() {
        deadlineTask?.cancel()
        deadlineTask = nil
        camera.stop()
    }

    func cancel() {
        isStopped = true
        stop()
    }

    private func consume(_ observation: FaceLivenessObservation?) {
        guard !isStopped, !isSubmitting, !showsFailure else { return }
        guard let observation, observation.isUsable else {
            noFaceFrames += 1
            if noFaceFrames >= 5 { fail(message: L10n.Wallet.livenessNoFace) }
            return
        }
        noFaceFrames = 0

        switch step {
        case .shake:
            let yaw = observation.yaw
            guard abs(yaw) >= 0.20 else { return }
            let direction = yaw >= 0 ? 1 : -1
            if let shakeDirection, shakeDirection != direction {
                advance()
            } else {
                shakeDirection = direction
            }
        case .nod:
            let pitch = observation.pitch
            guard abs(pitch) >= 0.14 else { return }
            let direction = pitch >= 0 ? 1 : -1
            if let nodDirection, nodDirection != direction {
                advance()
            } else {
                nodDirection = direction
            }
        case .front:
            if abs(observation.yaw) < 0.10, abs(observation.pitch) < 0.10 {
                frontFrames += 1
                if frontFrames >= 5 { captureAndVerify() }
            } else {
                frontFrames = 0
            }
        }
    }

    private func advance() {
        deadlineTask?.cancel()
        switch step {
        case .shake:
            step = .nod
            shakeDirection = nil
            nodDirection = nil
        case .nod:
            step = .front
            frontFrames = 0
        case .front:
            return
        }
        scheduleDeadline()
    }

    private func scheduleDeadline() {
        deadlineTask?.cancel()
        let currentStep = step
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.step == currentStep, !self.isSubmitting else { return }
                self.fail(message: L10n.Wallet.livenessTimedOut)
            }
        }
    }

    private func captureAndVerify() {
        isSubmitting = true
        deadlineTask?.cancel()
        camera.stop()
        Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await self.camera.captureLatestJPEG()
                try await self.verifyJPEG(image)
                AnalyticsTracker.track("h_faceID_sucess")
                self.didSucceed = true
            } catch {
                self.isSubmitting = false
                self.fail(message: (error as? APIError)?.message ?? L10n.Wallet.livenessUploadFailed)
            }
        }
    }

    private func fail(message: String) {
        guard !showsFailure else { return }
        deadlineTask?.cancel()
        camera.stop()
        failureMessage = message
        showsFailure = true
    }
}

private struct FaceLivenessObservation {
    let yaw: Double
    let pitch: Double
    let area: CGFloat

    var isUsable: Bool { area >= 0.055 }
}

final class FaceLivenessCameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    fileprivate var onObservation: ((FaceLivenessObservation?) -> Void)?
    var onFailure: (() -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.anchor.livechat.wallet.face.session")
    private let videoQueue = DispatchQueue(label: "com.anchor.livechat.wallet.face.video")
    private let latestFrameLock = NSLock()
    private let context = CIContext()
    private var latestPixelBuffer: CVPixelBuffer?
    private var configured = false
    private var lastAnalysisTime = CFAbsoluteTimeGetCurrent()

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configureIfNeeded()
                if !self.session.isRunning { self.session.startRunning() }
            } catch {
                DispatchQueue.main.async { self.onFailure?() }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func captureLatestJPEG() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            videoQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: WalletServiceError.invalidResponse)
                    return
                }
                self.latestFrameLock.lock()
                let buffer = self.latestPixelBuffer
                self.latestFrameLock.unlock()
                guard let buffer else {
                    continuation.resume(throwing: WalletServiceError.invalidResponse)
                    return
                }
                let image = CIImage(cvPixelBuffer: buffer)
                guard let data = self.context.jpegRepresentation(
                    of: image,
                    colorSpace: CGColorSpaceCreateDeviceRGB(),
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]
                ) else {
                    continuation.resume(throwing: WalletServiceError.invalidResponse)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw WalletServiceError.invalidResponse
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw WalletServiceError.invalidResponse }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { throw WalletServiceError.invalidResponse }
        session.addOutput(output)
        if let connection = output.connection(with: .video) {
            connection.videoOrientation = .portrait
            connection.isVideoMirrored = true
        }
        configured = true
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestFrameLock.lock()
        latestPixelBuffer = pixelBuffer
        latestFrameLock.unlock()

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAnalysisTime >= 0.20 else { return }
        lastAnalysisTime = now

        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
            let faces = request.results ?? []
            guard faces.count == 1, let face = faces.first else {
                DispatchQueue.main.async { [weak self] in self?.onObservation?(nil) }
                return
            }
            let yaw = face.yaw?.doubleValue ?? 0
            let pitch = face.pitch?.doubleValue ?? 0
            let area = face.boundingBox.width * face.boundingBox.height
            let observation = FaceLivenessObservation(
                yaw: yaw,
                pitch: pitch,
                area: area
            )
            DispatchQueue.main.async { [weak self] in self?.onObservation?(observation) }
        } catch {
            DispatchQueue.main.async { [weak self] in self?.onObservation?(nil) }
        }
    }
}

private struct FaceLivenessPreview: UIViewRepresentable {
    let camera: FaceLivenessCameraController

    func makeUIView(context: Context) -> FaceLivenessPreviewView {
        FaceLivenessPreviewView(session: camera.session)
    }

    func updateUIView(_ uiView: FaceLivenessPreviewView, context: Context) {}
}

private final class FaceLivenessPreviewView: UIView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        if let connection = previewLayer.connection {
            connection.videoOrientation = .portrait
            connection.isVideoMirrored = true
        }
    }
}
