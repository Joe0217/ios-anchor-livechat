import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "GiftMessageStore")

/// 私密媒体解锁 Store（H-2 spec §3 状态机 + 8 不变量）。
///
/// 三态独立管理：
/// - LoadState（拉资料）
/// - 编辑态（imagesEdit / videosEdit 数组，含 pending 集合）
/// - 视频解密态（signedUrl + signedAt + TTL refresh）
@MainActor
final class GiftMessageStore: ObservableObject {
    // MARK: - Published

    @Published private(set) var loadState: GiftMessageLoadState = .idle
    @Published private(set) var limit: PrivateMediaLimit = .default

    /// 原始列表（load 后固定不变，用于 diff 计算）
    @Published private(set) var imagesOriginal: [PrivateMedia] = []
    @Published private(set) var videosOriginal: [PrivateMedia] = []

    /// 当前编辑态（用户增删后的态）
    @Published private(set) var imagesEdit: [PrivateMedia] = []
    @Published private(set) var videosEdit: [PrivateMedia] = []

    /// 上传/删除中集合（防双击）
    @Published private(set) var pendingUploadIds: Set<String> = []
    @Published private(set) var isSaving: Bool = false

    /// GiftPicker sheet 显示态 + 待绑定项类别
    @Published var showingGiftPicker: Bool = false
    /// 最近上传项类别（sheet close 未选礼物时按此 pop 对应数组，修 H5 无差别 pop 图片 bug）
    @Published private(set) var pendingCategory: Int?  // 1=图片 / 2=视频
    /// 最近上传项 id（未选礼物 close 时 pop 该项）
    @Published private(set) var pendingBindId: String?

    @Published var transientError: String?

    // MARK: - Private

    private let service: GiftMessageServiceProtocol
    private let uploadService: PrivateMediaUploadServiceProtocol
    private let userId: Int
    /// 代际 token：每次 load 递增；outdated 上传/解密 drop
    private var loadGeneration: Int = 0
    /// 视频解密并发上限（spec §3.4 #8）
    private let decryptConcurrency = 3
    /// signedUrl TTL 阈值（spec §1.6 v2）：55min
    private let signedUrlTTL: TimeInterval = 55 * 60

    private let networkErrorFallback: String
    private let badFileFallback: String
    private let reachedLimitFallback: String
    private let selectGiftRequiredFallback: String

    // MARK: - Init

    init(userId: Int,
         service: GiftMessageServiceProtocol,
         uploadService: PrivateMediaUploadServiceProtocol,
         networkErrorFallback: String = "Network error, please try again.",
         badFileFallback: String = "Unsupported file",
         reachedLimitFallback: String = "Reached limit",
         selectGiftRequiredFallback: String = "Please select gift for all items") {
        self.userId = userId
        self.service = service
        self.uploadService = uploadService
        self.networkErrorFallback = networkErrorFallback
        self.badFileFallback = badFileFallback
        self.reachedLimitFallback = reachedLimitFallback
        self.selectGiftRequiredFallback = selectGiftRequiredFallback
    }

    // MARK: - Load（spec §3.1）

    func loadAll() async {
        guard !loadState.isLoading else { return }   // 不变量 #1
        loadGeneration += 1
        let gen = loadGeneration
        loadState = .loading

        // 并发拉 limit + list（limit 失败走默认，list 失败进 error 态）
        async let limFetch: PrivateMediaLimit = fetchLimitSafe()

        do {
            async let lstFetch: [PrivateMedia] = service.fetchList(userId: userId)
            let (lim, list) = try await (limFetch, lstFetch)
            // 代际过期 drop
            guard gen == loadGeneration else { return }

            limit = lim
            let images = list.filter { $0.isImage }
            let videos = list.filter { $0.isVideo }
            imagesOriginal = images
            imagesEdit = images
            videosOriginal = videos
            videosEdit = videos
            loadState = .loaded

            // 视频异步解密（限并发 3）
            await decryptAllVideos(gen: gen)
        } catch let e as APIError {
            guard gen == loadGeneration else { return }
            loadState = .error(e.message)
        } catch {
            guard gen == loadGeneration else { return }
            loadState = .error(error.localizedDescription)
        }
    }

    private func fetchLimitSafe() async -> PrivateMediaLimit {
        do { return try await service.fetchLimit() } catch { return .default }
    }

    // MARK: - 视频解密（spec §1.6 / §3.3 / §3.4 #6 #8）

    /// 批量解密 videosEdit（限并发 3）。
    private func decryptAllVideos(gen: Int) async {
        await withTaskGroup(of: (String, String?).self) { group in
            var running = 0
            var pending = videosEdit.filter { $0.signedUrl == nil }.map(\.id)
            var results: [(String, String?)] = []

            func launch(_ id: String) {
                group.addTask { [weak self, service] in
                    guard let self, let item = await self.videosEdit.first(where: { $0.id == id }) else {
                        return (id, nil)
                    }
                    do {
                        let signed = try await service.decryptVideoUrl(originalUrl: item.originalUrl)
                        return (id, signed)
                    } catch {
                        return (id, nil)
                    }
                }
                running += 1
            }

            // 初始化并发窗口
            while running < decryptConcurrency, !pending.isEmpty {
                launch(pending.removeFirst())
            }

            // 消费结果 + 补新任务
            for await result in group {
                results.append(result)
                running -= 1
                if !pending.isEmpty {
                    launch(pending.removeFirst())
                }
            }

            // 代际过期 drop
            guard gen == loadGeneration else { return }

            // 更新 videosEdit
            let now = Date()
            for (id, signed) in results {
                if let signed, let idx = videosEdit.firstIndex(where: { $0.id == id }) {
                    videosEdit[idx].signedUrl = signed
                    videosEdit[idx].signedAt = now
                }
            }
        }
    }

    /// TTL 检查 + 主动 refresh（播放前调）。
    func refreshSignedUrlIfNeeded(itemId: String) async {
        guard let idx = videosEdit.firstIndex(where: { $0.id == itemId }),
              let signedAt = videosEdit[idx].signedAt else {
            await refreshSignedUrl(itemId: itemId)
            return
        }
        if Date().timeIntervalSince(signedAt) >= signedUrlTTL {
            await refreshSignedUrl(itemId: itemId)
        }
    }

    /// 强制 refresh（TTL 到 / 403 触发）。
    func refreshSignedUrl(itemId: String) async {
        guard let idx = videosEdit.firstIndex(where: { $0.id == itemId }) else { return }
        let originalUrl = videosEdit[idx].originalUrl
        do {
            let signed = try await service.decryptVideoUrl(originalUrl: originalUrl)
            if let idx2 = videosEdit.firstIndex(where: { $0.id == itemId }) {
                videosEdit[idx2].signedUrl = signed
                videosEdit[idx2].signedAt = Date()
            }
        } catch {
            logger.warning("refreshSignedUrl failed for \(itemId, privacy: .private)")
        }
    }

    // MARK: - 上传（spec §3.2）

    /// 图片上传：走 ImageUploader（复用现成一站式封装）。
    func uploadImage(data: Data) async {
        guard imagesEdit.count < limit.privateNum else {
            transientError = reachedLimitFallback
            return
        }
        let localId = "local_\(UUID().uuidString)"
        pendingUploadIds.insert(localId)
        defer { pendingUploadIds.remove(localId) }

        do {
            let url = try await uploadService.uploadImage(data)
            let item = PrivateMedia(
                id: localId, iconType: 1, originalUrl: url,
                signedUrl: nil, signedAt: nil,
                giftId: "", giftName: nil, giftPrice: nil   // giftId 未选状态
            )
            imagesEdit.append(item)
            pendingCategory = 1
            pendingBindId = localId
            showingGiftPicker = true
        } catch {
            transientError = friendlyError(error)
            logger.error("uploadImage error: \(String(describing: error), privacy: .private)")
        }
    }

    /// 视频上传：走 STS + acl=private + timeout 60s（spec §5.2）。
    ///
    /// **step 3 反悔 #9 F1 修**：上传成功后**同步** decrypt 一次拿签名 URL 再 append。
    /// 曾经错误做法：signedUrl=originalUrl 初始化 + fire-and-forget refresh Task →
    /// 用户绑礼物后立即 tap 预览（refresh 未完成时）AVPlayer 拉未签名私密 URL 403 黑屏。
    /// spec F-11 "signedUrl 有效则直播" + §3.3 signedUrl 语义 = 签名 URL 而非直链。
    /// decrypt 失败宽松兜底 signedUrl=nil，走 §R-3 "视频解密失败 signedUrl=nil 占位"路径。
    func uploadVideo(fileURL: URL) async {
        guard videosEdit.count < limit.privateVedioNum else {
            transientError = reachedLimitFallback
            return
        }
        let localId = "local_\(UUID().uuidString)"
        pendingUploadIds.insert(localId)
        defer { pendingUploadIds.remove(localId) }

        do {
            let url = try await uploadService.uploadVideo(fileURL: fileURL)
            // 同步 decrypt 一次：成功 → signedUrl 直接可用；失败 → nil，占位路径接管
            let signedUrl = try? await service.decryptVideoUrl(originalUrl: url)
            let item = PrivateMedia(
                id: localId, iconType: 2, originalUrl: url,
                signedUrl: signedUrl,
                signedAt: signedUrl != nil ? Date() : nil,
                giftId: "", giftName: nil, giftPrice: nil
            )
            videosEdit.append(item)

            pendingCategory = 2
            pendingBindId = localId
            showingGiftPicker = true
        } catch {
            transientError = friendlyError(error)
            logger.error("uploadVideo error: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: - 礼物绑定（spec §1.5 / §1.8 修 H5 bug）

    /// 选礼物成功。
    func bindGift(_ gift: GiftMessageItem) {
        guard let bindId = pendingBindId, let category = pendingCategory else {
            showingGiftPicker = false
            return
        }
        // 按类别定位数组
        if category == 1, let idx = imagesEdit.firstIndex(where: { $0.id == bindId }) {
            imagesEdit[idx].giftId = gift.id
            imagesEdit[idx].giftName = gift.name
            imagesEdit[idx].giftPrice = gift.price
        } else if category == 2, let idx = videosEdit.firstIndex(where: { $0.id == bindId }) {
            videosEdit[idx].giftId = gift.id
            videosEdit[idx].giftName = gift.name
            videosEdit[idx].giftPrice = gift.price
        }
        pendingBindId = nil
        pendingCategory = nil
        showingGiftPicker = false
    }

    /// 礼物 sheet 关闭未选：pop **对应类别** 刚上传项（v2 修 H5 giftCloseOverlay 无差别 pop 图片 bug）。
    func cancelGiftBinding() {
        guard let bindId = pendingBindId, let category = pendingCategory else {
            showingGiftPicker = false
            return
        }
        if category == 1 {
            imagesEdit.removeAll { $0.id == bindId }
        } else if category == 2 {
            videosEdit.removeAll { $0.id == bindId }
        }
        pendingBindId = nil
        pendingCategory = nil
        showingGiftPicker = false
    }

    // MARK: - 删除

    func remove(itemId: String, category: Int) {
        if category == 1 {
            imagesEdit.removeAll { $0.id == itemId }
        } else if category == 2 {
            videosEdit.removeAll { $0.id == itemId }
        }
    }

    // MARK: - Submit（spec §1.5 diff + §3 不变量 #5）

    func submit() async -> Bool {
        guard !isSaving else { return false }
        // 校验所有项都绑了 giftId
        let allBound = (imagesEdit + videosEdit).allSatisfy { !$0.giftId.isEmpty }
        guard allBound else {
            transientError = selectGiftRequiredFallback
            return false
        }
        isSaving = true
        defer { isSaving = false }

        let imageOps = PrivateMediaDecoder.computeDiff(original: imagesOriginal, current: imagesEdit)
        let videoOps = PrivateMediaDecoder.computeDiff(original: videosOriginal, current: videosEdit)
        let ops = imageOps + videoOps

        do {
            try await service.save(ops: ops)
            logger.info("submit ok ops=\(ops.count, privacy: .public)")
            return true
        } catch {
            transientError = friendlyError(error)
            logger.error("submit error: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    // MARK: - Actions

    func retry() async { await loadAll() }

    func clearTransientError() { transientError = nil }

    // MARK: - View 派生

    var canSubmit: Bool {
        !isSaving && (imagesEdit + videosEdit).allSatisfy { !$0.giftId.isEmpty }
    }

    var canAddImage: Bool {
        imagesEdit.count < limit.privateNum && !isSaving
    }

    var canAddVideo: Bool {
        videosEdit.count < limit.privateVedioNum && !isSaving
    }

    // MARK: - Helpers

    private func friendlyError(_ error: Error) -> String {
        if let e = error as? APIError { return e.message }
        return networkErrorFallback
    }
}
