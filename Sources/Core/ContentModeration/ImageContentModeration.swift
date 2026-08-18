import CoreML
import Foundation
import ImageIO
import Vision

/// Result of the local image preflight.  This is intentionally separate from
/// the server moderation result: local inference is only a fast client gate.
enum ImageModerationDecision: Equatable {
    case allowed(confidence: Float)
    case blocked(confidence: Float)
    case unavailable
}

protocol ImageContentModerationServiceProtocol: Sendable {
    func check(data: Data) async -> ImageModerationDecision
}

/// Lazy, on-device Core ML NSFW preflight.
///
/// The model is loaded only when this service receives its first image.  The
/// resource is deliberately resolved by name instead of referencing a
/// generated model class, which keeps the model load behind the 107/register
/// feature gate and makes model replacement independent from Swift sources.
actor CoreMLImageContentModerationService: ImageContentModerationServiceProtocol {
    static let shared = CoreMLImageContentModerationService()

    private let modelResourceName: String
    private let blockedThreshold: Float
    private var visionModel: VNCoreMLModel?

    init(modelResourceName: String = "OpenNSFW8Bit",
         blockedThreshold: Float = 0.5) {
        self.modelResourceName = modelResourceName
        self.blockedThreshold = blockedThreshold
    }

    func check(data: Data) async -> ImageModerationDecision {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return .unavailable
        }

        do {
            let model = try loadModelIfNeeded()
            let observation = try await classify(image: image, model: model)
            guard let nsfw = observation else { return .unavailable }
            return nsfw >= blockedThreshold
                ? .blocked(confidence: nsfw)
                : .allowed(confidence: nsfw)
        } catch {
            return .unavailable
        }
    }

    private func loadModelIfNeeded() throws -> VNCoreMLModel {
        if let visionModel { return visionModel }
        guard let url = Bundle.main.url(forResource: modelResourceName,
                                        withExtension: "mlmodelc") else {
            throw ModelError.resourceMissing
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try VNCoreMLModel(for: MLModel(contentsOf: url,
                                                   configuration: configuration))
        visionModel = model
        return model
    }

    private func classify(image: CGImage,
                          model: VNCoreMLModel) async throws -> Float? {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNCoreMLRequest(model: model) { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNClassificationObservation]) ?? []
                let nsfwObservation = observations.first {
                    let identifier = $0.identifier.lowercased()
                    return identifier == "nsfw"
                        || identifier.contains("porn")
                        || identifier.contains("explicit")
                }
                continuation.resume(returning: nsfwObservation?.confidence)
            }
            request.imageCropAndScaleOption = .centerCrop
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private enum ModelError: Error {
        case resourceMissing
    }
}

/// Used by tests and by flows that deliberately have no image model enabled.
struct AllowAllImageContentModerationService: ImageContentModerationServiceProtocol {
    func check(data: Data) async -> ImageModerationDecision {
        .allowed(confidence: 0)
    }
}
