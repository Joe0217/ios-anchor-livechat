import Foundation
import AVFoundation
import os

/// 二次压缩：1080p 原始 mov (~10MB) → 1080p H.264 ~2.5Mbps mp4 (~5-6MB)
///
/// 保留分辨率（画质 80% 感受），降码率（体积压缩 50%+；对齐 spec §4.2 v3 + 需求文档"画质 80% 体积 50%+"）。
/// AVAssetWriter + AVAssetReader 精确控参数：AVVideoAverageBitRateKey = 2_500_000 + AVVideoProfileLevelH264HighAutoLevel。
enum RegisterVideoCompressor {

    private static let logger = Logger(subsystem: "com.anchor.livechat", category: "RegisterCompressor")

    /// - parameter sourceUrl: 录制产出的 mov
    /// - parameter progressHandler: 0.0 → 1.0 主线程回调
    /// - returns: 压缩后 mp4 临时路径
    static func compress(
        sourceUrl: URL,
        progressHandler: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {

        let outputUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("register-compressed-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputUrl)

        let asset = AVURLAsset(url: sourceUrl)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw RegisterVideoError.compressFailed("no video track")
        }
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first

        // AVAssetReader
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        )
        reader.add(videoOutput)

        // Bug fix 2026-07-10：audio reader outputSettings 必须指定 uncompressed LPCM，
        // 因为 audio writer input 有 outputSettings (AAC 编码)，AVAssetWriter 要求 append 的 sample buffer 为 uncompressed；
        // 原 `outputSettings: nil` → reader 直接输出 AAC compressed samples → append 抛
        //   NSInvalidArgumentException "Input buffer must be in an uncompressed format when outputSettings is not nil"
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            reader.add(out)
            audioOutput = out
        }

        // AVAssetWriter (mp4)
        let writer = try AVAssetWriter(outputURL: outputUrl, fileType: .mp4)

        // Bug fix 2026-07-08：**用 source naturalSize 作 outputSize + 保留 transform**
        // 原写死 1080x1920 竖屏 + transform 组合会导致 sample append 挂：
        // - iPhone 前置录制 hd1920x1080 preset 实际 naturalSize=1920x1080 (landscape 存储)
        // - preferredTransform 是 90° rotate (仅显示时应用；存储方向仍 landscape)
        // - outputSize 写死 1080x1920 (portrait) + transform 90° → writer 期望 rotated portrait 输入
        //   但 sample buffer 来自 landscape source → 尺寸不匹配 → append 静默失败 / 挂住
        // 正解：outputSize 用 source naturalSize（自然存储方向），transform 保留（metadata 层旋转显示）
        let naturalSize = try await videoTrack.load(.naturalSize)
        let outputWidth = Int(naturalSize.width)
        let outputHeight = Int(naturalSize.height)
        let transform = try await videoTrack.load(.preferredTransform)
        logger.info("[Compressor] source naturalSize=\(naturalSize.width, privacy: .public)x\(naturalSize.height, privacy: .public) transform=\(String(describing: transform), privacy: .public)")

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 30
            ]
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform   // 仅 metadata 旋转显示，不改 sample 排布
        writer.add(videoInput)

        // Audio input: AAC 128kbps 44.1kHz stereo
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        // 启动 read & write
        guard reader.startReading() else {
            throw RegisterVideoError.compressFailed("reader start failed: \(reader.error?.localizedDescription ?? "-")")
        }
        guard writer.startWriting() else {
            throw RegisterVideoError.compressFailed("writer start failed: \(writer.error?.localizedDescription ?? "-")")
        }
        writer.startSession(atSourceTime: .zero)

        let totalDuration = try await asset.load(.duration).seconds
        let queue = DispatchQueue(label: "register.compress.\(UUID().uuidString)")

        // 并行拉视频 + 音频
        async let videoDone: Void = pumpTrack(
            input: videoInput, output: videoOutput, queue: queue,
            totalDuration: totalDuration, progressHandler: progressHandler
        )

        if let audioInput, let audioOutput {
            async let audioDone: Void = pumpTrack(
                input: audioInput, output: audioOutput, queue: queue,
                totalDuration: totalDuration, progressHandler: { _ in }
            )
            _ = try await (videoDone, audioDone)
        } else {
            _ = try await videoDone
        }

        await writer.finishWriting()
        if writer.status == .failed {
            let msg = writer.error?.localizedDescription ?? "writer failed"
            logger.error("[Compressor] writer failed: \(msg, privacy: .public)")
            throw RegisterVideoError.compressFailed(msg)
        }

        await MainActor.run { progressHandler(1.0) }
        let outSize = (try? FileManager.default.attributesOfItem(atPath: outputUrl.path)[.size] as? Int) ?? 0
        logger.info("[Compressor] done size=\(outSize, privacy: .public) bytes")
        return outputUrl
    }

    private static func pumpTrack(
        input: AVAssetWriterInput,
        output: AVAssetReaderTrackOutput,
        queue: DispatchQueue,
        totalDuration: Double,
        progressHandler: @escaping @MainActor (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var didResume = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        // Reader 读完
                        input.markAsFinished()
                        if !didResume {
                            didResume = true
                            cont.resume()
                        }
                        return
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    if totalDuration > 0 {
                        let p = min(1.0, pts / totalDuration)
                        Task { @MainActor in progressHandler(p) }
                    }
                    // Bug fix 2026-07-08：append 返回 false 时 writer 挂了，早 throw 让上层看到错误而非无限卡 processing
                    if !input.append(sample) {
                        input.markAsFinished()
                        if !didResume {
                            didResume = true
                            cont.resume(throwing: RegisterVideoError.compressFailed("input.append returned false (writer likely failed)"))
                        }
                        return
                    }
                }
            }
        }
    }
}
