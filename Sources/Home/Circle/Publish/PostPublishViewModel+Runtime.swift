import Foundation

/// runtime 工厂：注入 L10n 文案 + 生产 services + `ImageCompressor.moment` preset。
///
/// **不入 HilyTests sources**（依赖 L10n / ImageCompressor.UIKit / Service.shared）；
/// 单测直接构造 `PostPublishViewModel(service:, credentialService:, ossService:, compressImage:)` 注入 Fake。
/// 对齐 [BlocklistViewModel+Runtime.swift](../../../Profile/Settings/Blocklist/BlocklistViewModel+Runtime.swift) 同款拆法。
extension PostPublishViewModel {

    /// 从 L10n 取真实文案；HilyTests 用 `.englishFallback`。
    static var localizedStrings: PostPublishStrings {
        PostPublishStrings(
            textEmpty:         L10n.Publish.textEmpty,
            noImages:          L10n.Publish.noImages,
            imageTooLarge:     L10n.Publish.imageTooLarge,
            credentialFailed:  L10n.Publish.credentialFailed,
            uploadFailed:      L10n.Publish.uploadFailed,
            createFailed:      L10n.Publish.createFailed,
            networkError:      L10n.Publish.networkError,
            publishSuccess:    L10n.Publish.publishSuccess
        )
    }

    /// 生产 runtime 工厂。默认注入 `PostPublishService.shared` / `OssCredentialService.shared` /
    /// `OssUploadService.shared` + `ImageCompressor.compress(preset:.moment)`。
    static func makeRuntime(service: PostPublishServiceProtocol = PostPublishService.shared,
                            credentialService: OssCredentialServiceProtocol = OssCredentialService.shared,
                            ossService: OssUploadServiceProtocol = OssUploadService.shared) -> PostPublishViewModel {
        PostPublishViewModel(
            service: service,
            credentialService: credentialService,
            ossService: ossService,
            compressImage: { try ImageCompressor.compress(rawData: $0, preset: .moment) },
            strings: localizedStrings
        )
    }
}
