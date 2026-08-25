import Foundation
import os

private let logger = Logger(subsystem: "com.hilly.anchor", category: "PostPublishVM")

/// 朋友圈发布页 ViewModel（J spec §4 状态机）。
///
/// **核心设计**：
/// - 状态机单一 active state；非法迁移由 enum case 直接拒绝
/// - `uploadEpoch` 守 stale callback：cancel 后到达的旧 epoch 回调不可推进状态机（红队 #6）
/// - `uploadedUrls` 跨重试单调累积，重试时跳过已成功 idx（红队 #4 + 用户 Q4 调和）
/// - STS 凭证寿命：上传前预检 expire；OSS 返 SecurityTokenExpired 自动重拉最多 2 次（spec R18/R19）
/// - dismiss 时 cancel 所有 inflight upload Task；create 已发出**不 cancel**，仍 post `.momentPublished`（spec R21）
/// - 失败兜底文案走 L10n 注入（HilyTests 不依赖 L10n，单测注入英文兜底）
@MainActor
final class PostPublishViewModel: ObservableObject {

    // MARK: - 输入

    @Published var text: String = "" {
        didSet {
            // 防粘贴超长（spec R4）
            if text.count > PostPublishLimits.maxTextLength {
                text = String(text.prefix(PostPublishLimits.maxTextLength))
            }
            // 修改被拦截的文字后，清除旧的失败状态，允许重新发布。
            if case .failed(.contentRejected, _) = state {
                state = .editing
                transientError = nil
            }
        }
    }
    /// 原始图片数据数组（按选图顺序）。
    /// 选图阶段已做 > 10MB 拒绝（外层 view + ImageCompressor 配合）
    @Published private(set) var imageDataList: [Data] = []
    /// 选图后立即更新的本地审核状态，索引与 imageDataList 一一对应。
    @Published private(set) var imageModerationStates: [ImageModerationStatus] = []

    // MARK: - 输出

    @Published private(set) var state: PostingState = .editing
    /// transient 错误文案（toast，2s 自动消失；对齐 BlocklistView 模式）
    @Published var transientError: String?

    // MARK: - 依赖注入

    /// 业务层：调 `friendsCircle/create`（[PostPublishService](PostPublishService.swift)）
    private let service: PostPublishServiceProtocol
    /// 通用能力：拿 OSS 凭证（[OssCredentialService](../../../Core/Upload/OssCredentialService.swift)）
    private let credentialService: OssCredentialServiceProtocol
    /// 通用能力：OSS multipart 上传（[OssUploadService](../../../Core/Upload/OssUploadService.swift)）
    private let ossService: OssUploadServiceProtocol
    /// 压缩函数（runtime 注入 `ImageCompressor.compress`，单测注入 identity 或 mock）
    private let compressImage: (Data) throws -> Data
    /// 图片预检。普通账号注入 allow-all，107 runtime 才注入惰性 Core ML 服务。
    private let imageModerationService: ImageContentModerationServiceProtocol
    private let textModerationEnabled: Bool
    /// "now" 注入便于单测 R18 expire 预检；生产传 `{ Date().timeIntervalSince1970 }`
    private let nowEpoch: () -> TimeInterval
    /// 文案注入（HilyTests 不依赖 L10n）
    private let strings: PostPublishStrings

    // MARK: - 内部状态

    /// 缓存当次发布动作的 STS 凭证。dismiss / success 时清空
    private var currentCredential: OssCredential?
    /// 当前上传轮次。每次进入 uploadingImages +1；stale callback 守卫据此判断（红队 #6）
    private var currentEpoch: Int = 0
    /// 单次发布内 STS 重拉计数；超过 maxCredentialRefreshPerPublish 转 credentialFailed
    private var credentialRefreshCount: Int = 0
    /// 进行中的 upload Task（idx → Task），cancel / deinit 时统一调 cancel
    private var inflightUploadTasks: [Int: Task<Void, Never>] = [:]
    /// create Task（spec R21：dismiss 时不 cancel 这个）
    private var inflightCreateTask: Task<Void, Never>?

    enum ImageModerationStatus: Equatable {
        case checking
        case allowed
        case blocked
        case unavailable
    }

    init(service: PostPublishServiceProtocol,
         credentialService: OssCredentialServiceProtocol,
         ossService: OssUploadServiceProtocol,
         compressImage: @escaping (Data) throws -> Data,
         imageModerationService: ImageContentModerationServiceProtocol = AllowAllImageContentModerationService(),
         textModerationEnabled: Bool = false,
         nowEpoch: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         strings: PostPublishStrings = .englishFallback) {
        self.service = service
        self.credentialService = credentialService
        self.ossService = ossService
        self.compressImage = compressImage
        self.imageModerationService = imageModerationService
        self.textModerationEnabled = textModerationEnabled
        self.nowEpoch = nowEpoch
        self.strings = strings
    }

    deinit {
        // INV5：所有 inflight 上传 Task 调 cancel；create Task 不 cancel（spec R21）
        // 注：deinit 在 @MainActor 上不能 await，直接同步 cancel
        for (_, task) in inflightUploadTasks { task.cancel() }
        inflightUploadTasks.removeAll()
        // create 已发出 → 不 cancel；deinit 时仍 post .momentPublished 让 me sub-tab 刷新
        // 但 deinit 走到说明 view 已被销毁，应已 post 过（success 路径 / dismiss 兜底）
    }

    // MARK: - 输入操作

    /// 选图阶段添加图片（已通过 view 层 > 10MB 拒绝）
    func appendImage(rawData: Data) {
        guard imageDataList.count < PostPublishLimits.maxImageCount else { return }
        guard rawData.count / 1024 <= PostPublishLimits.maxImageRawKB else {
            transientError = strings.imageTooLarge
            return
        }
        imageDataList.append(rawData)
        imageModerationStates.append(.checking)
        let index = imageDataList.count - 1
        Task { [weak self] in
            guard let self else { return }
            let decision = await self.imageModerationService.check(data: rawData)
            guard self.imageDataList.indices.contains(index), self.imageDataList[index] == rawData else { return }
            switch decision {
            case .allowed: self.imageModerationStates[index] = .allowed
            case .blocked:
                self.imageModerationStates[index] = .blocked
                self.transientError = self.strings.contentRejected
            case .unavailable:
                self.imageModerationStates[index] = .unavailable
                self.transientError = self.strings.contentCheckUnavailable
            }
        }
    }

    func removeImage(at idx: Int) {
        guard imageDataList.indices.contains(idx) else { return }
        imageDataList.remove(at: idx)
        if imageModerationStates.indices.contains(idx) {
            imageModerationStates.remove(at: idx)
        }
        // Removing the image that caused the local moderation failure returns
        // the editor to an actionable state. Without this, the state machine
        // remains in `.failed(.contentRejected)` and Release stays disabled.
        switch state {
        case .checkingContent:
            state = .editing
        case .failed(.contentRejected, _), .failed(.contentCheckUnavailable, _):
            state = .editing
            transientError = nil
        default:
            break
        }
    }

    /// 是否可点发布按钮（前端 disable，spec F7）
    var canPublish: Bool {
        guard case .editing = state else { return false }
        guard !trimmedText.isEmpty, !imageDataList.isEmpty else { return false }
        return imageModerationStates.allSatisfy {
            if case .blocked = $0 { return false }
            if case .unavailable = $0 { return false }
            if case .checking = $0 { return false }
            return true
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 主流程：publish

    /// 触发发布（用户点 Release 按钮）。
    /// 状态机：editing → checkingContent → uploadingImages → creatingPost → success
    /// 或：→ failed(原因)
    func publish() {
        guard case .editing = state else { return }  // R13 防双发布

        // F4 / R1 / R2 前置 guard
        let trimmed = trimmedText
        if trimmed.isEmpty {
            transientError = strings.textEmpty
            state = .failed(reason: .textEmpty, uploadedUrls: [:])
            return
        }
        if imageDataList.isEmpty {
            transientError = strings.noImages
            state = .failed(reason: .noImages, uploadedUrls: [:])
            return
        }
        if textModerationEnabled,
           ObjectionableContentFilter.containsObjectionableContent(trimmed) {
            transientError = strings.contentRejected
            state = .failed(reason: .contentRejected, uploadedUrls: [:])
            return
        }

        // 同步切到 checkingContent：让 canPublish 立即返 false（R13 同步守）。
        // epoch +=1 也在同步，让 stale callback 立即被守住
        currentEpoch += 1
        state = .checkingContent
        let epoch = currentEpoch
        Task { await runUploadFlow(epoch: epoch, uploadedUrls: [:]) }
    }

    /// 用户在 failed 态点重试。
    /// - uploadFailed / credentialFailed / network → 重走上传（跳过 uploadedUrls 已有 idx）
    /// - createFailed → 直接重发 create（不重传图）
    func retry() {
        guard case .failed(let reason, let uploadedUrls) = state else { return }
        switch reason {
        case .textEmpty, .noImages, .contentRejected, .contentCheckUnavailable:
            // 回 editing 让用户改输入
            state = .editing
        case .createFailed:
            // R9：图已上传，直接重发 create（同步切 state 防重试中再触发）
            currentEpoch += 1
            let imgUrls = orderedUrls(uploadedUrls: uploadedUrls)
            state = .creatingPost(imgUrls: imgUrls)
            Task { await runCreateFlow(imgUrls: imgUrls, uploadedUrlsSnapshot: uploadedUrls) }
        case .credentialFailed, .uploadFailed, .network:
            // 重置凭证重拉计数（用户主动重试视为新一轮）
            credentialRefreshCount = 0
            currentEpoch += 1
            state = .uploadingImages(progress: uploadedUrls.count,
                                      total: imageDataList.count,
                                      uploadedUrls: uploadedUrls)
            let epoch = currentEpoch
            Task { await runUploadFlow(epoch: epoch, uploadedUrls: uploadedUrls) }
        }
    }

    /// 用户在 failed / editing 态回到编辑（dismiss 替代品）
    func backToEditing() {
        guard case .failed = state else { return }
        state = .editing
    }

    /// spec R21：dismiss 时调用。
    /// - 取消所有 inflight upload Task（create 不取消）
    /// - 若已进入 success → 不需操作（toast 后自然 dismiss）
    /// - 若处于 creatingPost → 不阻塞（让 create 继续；ViewModel 内 broadcast 已在 success 时发，
    ///   万一 dismiss 在 create 完成前发生，不再有 view 监听，但 .momentPublished 已 post 是关键）
    func cancelInflightForDismiss() {
        cancelUploadTasks()
        // inflightCreateTask 不取消（R21）
    }

    // MARK: - 上传流程

    /// 由 publish / retry 调用：epoch + state 已由调用方同步设置；本函数仅做 async 流程。
    private func runUploadFlow(epoch: Int, uploadedUrls: [Int: String]) async {
        let total = imageDataList.count

        // Do not request credentials or upload media until the local image
        // gate has accepted every image. The normal-account service is a no-op.
        if uploadedUrls.isEmpty {
            for (idx, data) in imageDataList.enumerated() {
                guard epoch == currentEpoch else { return }
                let status = imageModerationStates.indices.contains(idx) ? imageModerationStates[idx] : .checking
                switch status {
                case .allowed:
                    continue
                case .blocked:
                    state = .failed(reason: .contentRejected, uploadedUrls: [:])
                    transientError = strings.contentRejected
                    return
                case .unavailable:
                    logger.error("local image moderation unavailable idx=\(idx, privacy: .public)")
                    state = .failed(reason: .contentCheckUnavailable, uploadedUrls: [:])
                    transientError = strings.contentCheckUnavailable
                    return
                case .checking:
                    switch await imageModerationService.check(data: data) {
                    case .allowed:
                        if imageModerationStates.indices.contains(idx) { imageModerationStates[idx] = .allowed }
                    case .blocked:
                        if imageModerationStates.indices.contains(idx) { imageModerationStates[idx] = .blocked }
                        state = .failed(reason: .contentRejected, uploadedUrls: [:])
                        transientError = strings.contentRejected
                        return
                    case .unavailable:
                        if imageModerationStates.indices.contains(idx) { imageModerationStates[idx] = .unavailable }
                        state = .failed(reason: .contentCheckUnavailable, uploadedUrls: [:])
                        transientError = strings.contentCheckUnavailable
                        return
                    }
                }
            }
        }

        // 1. STS 凭证（预检 expire，spec R18）
        guard let credential = await ensureCredential(epoch: epoch) else { return }
        if epoch != currentEpoch { return }  // stale guard

        // 2. 并发上传所有未完成的 idx
        var currentUploaded = uploadedUrls
        let pendingIdxs = (0..<total).filter { currentUploaded[$0] == nil }
        if pendingIdxs.isEmpty {
            // 所有都已上传（罕见 case：retry 后无需上传），直进 create
            let imgUrls = orderedUrls(uploadedUrls: currentUploaded)
            state = .creatingPost(imgUrls: imgUrls)
            await runCreateFlow(imgUrls: imgUrls, uploadedUrlsSnapshot: currentUploaded)
            return
        }

        // 顺序上传（简化错误处理；并发上传作为后续优化）
        // 注：spec R8 要求"任一失败立即 cancel 其余"——顺序上传天然满足（失败即停）
        for idx in pendingIdxs {
            if epoch != currentEpoch { return }  // stale guard

            let rawData = imageDataList[idx]
            // 压缩（HEIC → JPEG，>300KB 才压）
            let compressed: Data
            do {
                compressed = try compressImage(rawData)
            } catch {
                logger.error("compress idx=\(idx) failed: \(String(describing: error))")
                if epoch == currentEpoch {
                    state = .failed(reason: .uploadFailed(idx: idx), uploadedUrls: currentUploaded)
                    transientError = strings.uploadFailed
                }
                return
            }

            // 拼 OSS object key + 上传
            let objectKey = makeObjectKey(now: Date(timeIntervalSince1970: nowEpoch()))

            do {
                let url = try await ossService.uploadImage(imageData: compressed,
                                                           credential: credential,
                                                           objectKey: objectKey)
                if epoch != currentEpoch { return }  // stale guard
                currentUploaded[idx] = url
                state = .uploadingImages(progress: currentUploaded.count,
                                          total: total,
                                          uploadedUrls: currentUploaded)
            } catch let e as OssUploadError where e.isTokenExpired {
                // spec R19：STS 过期 → 重拉 + 重传剩余
                if epoch != currentEpoch { return }
                if credentialRefreshCount < PostPublishLimits.maxCredentialRefreshPerPublish {
                    credentialRefreshCount += 1
                    currentCredential = nil
                    logger.info("OSS token expired, refresh STS count=\(self.credentialRefreshCount)")
                    // 递归重新走 upload flow，跳过已成功 idx
                    currentEpoch += 1
                    state = .uploadingImages(progress: currentUploaded.count,
                                              total: total,
                                              uploadedUrls: currentUploaded)
                    let nextEpoch = currentEpoch
                    await runUploadFlow(epoch: nextEpoch, uploadedUrls: currentUploaded)
                } else {
                    state = .failed(reason: .credentialFailed, uploadedUrls: currentUploaded)
                    transientError = strings.credentialFailed
                }
                return
            } catch {
                if epoch != currentEpoch { return }
                logger.error("upload idx=\(idx) failed: \(String(describing: error))")
                state = .failed(reason: .uploadFailed(idx: idx), uploadedUrls: currentUploaded)
                transientError = strings.uploadFailed
                return
            }
        }

        // 3. 全部上传成功 → create
        if epoch != currentEpoch { return }
        let imgUrls = orderedUrls(uploadedUrls: currentUploaded)
        state = .creatingPost(imgUrls: imgUrls)
        await runCreateFlow(imgUrls: imgUrls, uploadedUrlsSnapshot: currentUploaded)
    }

    /// STS 凭证获取：复用 currentCredential（若未过期）；否则重拉。
    /// **R18 防御**：服务端理论上不该返临期凭证，但客户端最多再拉 1 次防御（极端 case）。
    private func ensureCredential(epoch: Int) async -> OssCredential? {
        if let cached = currentCredential,
           !cached.shouldRefresh(nowEpoch: nowEpoch(),
                                 safetyMargin: PostPublishLimits.credentialRefreshMargin) {
            return cached
        }
        // 拉新凭证；若服务端返回的也临期，再拉 1 次（最多 2 次总尝试）
        var lastFetched: OssCredential?
        for attempt in 0..<2 {
            do {
                let next = try await credentialService.getOssUploadParam()
                if epoch != currentEpoch { return nil }  // stale guard
                if next.shouldRefresh(nowEpoch: nowEpoch(),
                                      safetyMargin: PostPublishLimits.credentialRefreshMargin) {
                    // 服务端返临期凭证，尝试再拉一次
                    lastFetched = next
                    logger.warning("STS returned near-expiry credential, retry attempt=\(attempt + 1)")
                    continue
                }
                currentCredential = next
                return next
            } catch {
                if epoch != currentEpoch { return nil }
                logger.error("getOssUploadParam failed: \(String(describing: error))")
                state = .failed(reason: .credentialFailed,
                                uploadedUrls: state.uploadedUrlsSnapshot)
                transientError = strings.credentialFailed
                return nil
            }
        }
        // 2 次都临期 → 用最后一次（兜底，让流程继续；OSS 失败后走 R19 路径）
        if let last = lastFetched {
            currentCredential = last
            return last
        }
        return nil
    }

    // MARK: - create 流程

    /// state 已由调用方同步设置为 .creatingPost；本函数仅做 async 网络 + 状态推进。
    private func runCreateFlow(imgUrls: [String], uploadedUrlsSnapshot: [Int: String]) async {
        do {
            try await service.createPost(textContent: trimmedText, imgUrls: imgUrls)
            state = .success
            // INV4：发布成功广播。
            // 注：CircleService me feed 端会收到通知 + pendingReload；
            //    keep-alive 下 me sub-tab isActive 才 fetch（对齐项目 rule）
            NotificationCenter.default.post(name: .momentPublished, object: nil)
            transientError = strings.publishSuccess
        } catch let e as APIError {
            // R10/R22：业务码非 0000，按 message 显示 toast（v3 不区分审核拒绝）
            state = .failed(reason: .createFailed(msg: e.message),
                            uploadedUrls: uploadedUrlsSnapshot)
            transientError = e.message.isEmpty ? strings.createFailed : e.message
        } catch {
            state = .failed(reason: .network, uploadedUrls: uploadedUrlsSnapshot)
            transientError = strings.networkError
        }
    }

    // MARK: - Helpers

    /// uploadedUrls map → 顺序 url 数组（按 idx 升序，确保发布顺序与选图顺序一致）
    private func orderedUrls(uploadedUrls: [Int: String]) -> [String] {
        uploadedUrls.sorted { $0.key < $1.key }.map { $0.value }
    }

    /// 拼 OSS object key：`hiFunny/{yyyyMMdd}/{UUID}.jpg`
    private func makeObjectKey(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")  // 对齐 CLAUDE.md 时区纪律
        let dateStr = formatter.string(from: now)
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "hiFunny/\(dateStr)/\(uuid).jpg"
    }

    /// dismiss 时 cancel 所有 upload Task
    private func cancelUploadTasks() {
        for (_, task) in inflightUploadTasks { task.cancel() }
        inflightUploadTasks.removeAll()
        currentEpoch += 1  // 让所有 stale callback 都被守住
    }

    #if DEBUG
    /// Preview 工厂
    static func preview(state: PostingState = .editing,
                        text: String = "",
                        imageDataList: [Data] = []) -> PostPublishViewModel {
        let vm = PostPublishViewModel(
            service: PreviewPostPublishService(),
            credentialService: PreviewCredentialService(),
            ossService: PreviewOssUploadService(),
            compressImage: { $0 }
        )
        vm.text = text
        vm.imageDataList = imageDataList
        vm.state = state
        return vm
    }
    #endif
}

// MARK: - 文案注入（HilyTests 不依赖 L10n）

struct PostPublishStrings {
    let textEmpty: String
    let noImages: String
    let imageTooLarge: String
    let credentialFailed: String
    let uploadFailed: String
    let createFailed: String
    let networkError: String
    let publishSuccess: String
    let contentRejected: String
    let contentCheckUnavailable: String

    static let englishFallback = PostPublishStrings(
        textEmpty: "Please enter content",
        noImages: "Please add at least 1 image",
        imageTooLarge: "Image too large",
        credentialFailed: "Failed to get upload credential",
        uploadFailed: "Upload failed, please retry",
        createFailed: "Publish failed",
        networkError: "Network error, please try again",
        publishSuccess: "Successfully published",
        contentRejected: "This image cannot be published",
        contentCheckUnavailable: "Unable to check image content"
    )
}

// MARK: - 便利访问

private extension PostingState {
    /// 提取当前 uploadedUrls（用于 state 切换时保留累积）
    var uploadedUrlsSnapshot: [Int: String] {
        switch self {
        case .uploadingImages(_, _, let urls): return urls
        case .failed(_, let urls):              return urls
        default:                                return [:]
        }
    }
}

#if DEBUG
private final class PreviewPostPublishService: PostPublishServiceProtocol {
    func createPost(textContent: String, imgUrls: [String]) async throws {
        try await Task.sleep(nanoseconds: .max)
    }
}

private final class PreviewCredentialService: OssCredentialServiceProtocol {
    func getOssUploadParam() async throws -> OssCredential {
        try await Task.sleep(nanoseconds: .max)
        fatalError()
    }
}

private final class PreviewOssUploadService: OssUploadServiceProtocol {
    func uploadImage(imageData: Data, credential: OssCredential, objectKey: String) async throws -> String {
        try await Task.sleep(nanoseconds: .max)
        fatalError()
    }
    func uploadVideo(videoData: Data, credential: OssCredential, objectKey: String, contentType: String) async throws -> String {
        try await Task.sleep(nanoseconds: .max)
        fatalError()
    }
}
#endif
