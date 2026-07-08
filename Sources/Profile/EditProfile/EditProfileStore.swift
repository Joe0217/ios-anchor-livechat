import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "EditProfileStore")

/// 用户资料编辑页状态机（I-spec §3 · Step 1a）。
///
/// 副作用（真接口调用 / 上传）全收敛在本 Store，View 只订阅 @Published 状态。
/// 单测通过注入 Fake service + 手动调 `markPhotoUploaded` 等方法覆盖上传结果分支
/// （避免单测里真跑 async URLSession）。
///
/// 关键不变量：
/// - View 只读 `@Published` 状态（private(set)）
/// - Upload Epoch 守 stale callback：dismiss / retry / 覆盖上传时递增
/// - phase 转 `.terminated` 后不再接受任何用户操作（apiSessionInvalidated 触发）
@MainActor
final class EditProfileStore: ObservableObject {

    // MARK: - Published State

    @Published private(set) var phase: EditProfilePhase = .loading
    @Published private(set) var draft: DraftState = .empty
    @Published private(set) var review: ReviewStatus = .none
    @Published private(set) var originalSnapshot: OriginalSnapshot = .empty

    /// 无 fetch 之前的 loadError 消息；用户点 Retry 重跑 load
    @Published private(set) var loadErrorMessage: String? = nil

    /// Transient toast 语义 key（View 层翻译为 L10n 文案）；view 消费后 clear
    @Published private(set) var transientToast: EditProfileToastKey? = nil

    /// SWR 后台刷新中标记（View 用于 media section skeleton 展示）
    /// hydrate 秒开 4 基础字段后启动 refresh；true=期间 photos/videos/callVideo 显示 shimmer 骨架
    @Published private(set) var isRefreshing: Bool = false

    // MARK: - Deps & Internal

    private let service: EditProfileServiceProtocol
    private(set) var uploadEpoch: Int = 0
    private var sessionInvalidatedObserver: NSObjectProtocol?

    /// SWR 后台刷新任务句柄，供 `awaitPendingRefresh` 在 Confirm 前 join 完成
    /// 保存竞态防御：若 hydrate 后 200ms 内用户点 Confirm，review 尚未拉到，
    /// 会把审核中字段一并提交被后端 reject。await 完成后 review 就位。
    private var refreshingTask: Task<Void, Never>?

    /// spec §3.3 / N-34：切后台的时戳（前台时为 nil）
    private var enteredBackgroundAt: Date?
    /// spec §3.3 / N-34：后台超时阈值 —— URLSession 后台被系统挂起假设
    private static let backgroundUploadTimeoutSec: TimeInterval = 60

    // MARK: - Init

    init(service: EditProfileServiceProtocol) {
        self.service = service
        registerSessionInvalidatedObserver()
    }

    deinit {
        if let obs = sessionInvalidatedObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func registerSessionInvalidatedObserver() {
        sessionInvalidatedObserver = NotificationCenter.default.addObserver(
            forName: .apiSessionInvalidated, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSessionInvalidated() }
        }
    }

    // MARK: - Loading

    /// 首次进入 / Retry 触发；并发拉 checkUserInfo + userInfoWithReview
    func load() async {
        phase = .loading
        loadErrorMessage = nil

        do {
            async let check = service.fetchCheckUserInfo()
            async let info = service.fetchUserInfoWithReview()
            let (checkResult, infoResult) = try await (check, info)
            applyLoadResult(check: checkResult, info: infoResult)
            phase = .editing
        } catch {
            logger.error("load failed: \(String(describing: error))")
            let msg = "\(error.localizedDescription)"
            phase = .loadError(msg)
            loadErrorMessage = msg
        }
    }

    func retry() async {
        guard case .loadError = phase else { return }
        await load()
    }

    private func applyLoadResult(check: CheckUserInfoResponse, info: UserInfoWithReviewResponse) {
        let (newReview, newSnapshot, newDraft) = Self.buildLoadArtifacts(check: check, info: info)
        review = newReview
        originalSnapshot = newSnapshot
        draft = newDraft
    }

    /// 从 check + info 接口响应构建 review + snapshot + draft。
    ///
    /// 抽为 static 方法后可被 `applyLoadResult`（初次拉取）和 `mergeRefreshResult`（SWR 后台刷新）复用。
    ///
    /// **draft 与 snapshot 的分工**（2026-07-08 对齐 H5 profile/index.vue:107-118）：
    /// - `originalSnapshot`：保存"当前已通过审核的老值"（`anchor.nickname/icon/signature/...`），diff 基线
    /// - `draft`：显示给用户的值。**若字段审核中，用审核值**（`check.nickname` / 审核中头像 `mediaUrl`）；
    ///   否则用老值（= snapshot 值）。这样用户在编辑页看到的是"自己提交审核的内容"而非"审核前的老内容"。
    /// - `buildUpdateRequest` 里的 `if draft.X != orig.X, !review.X { req.X = draft.X }` 逻辑不变——
    ///   审核中字段被 `!review.X` 拦截不会误提交，即使 draft.X 是审核值也无害。
    ///
    /// - Step 3 反悔 #3-3：真接口用 `picList` 单一数组，`mediaType` 1=图片 2=视频；
    ///   AnchorInfo.pictures/videos 是 iOS 侧臆想字段（现有 ProfileModels.swift 就标"待真机校验"），
    ///   后端不返 → 之前 photos/videos 全空。
    ///   修法：优先用 info.picList 分流；空则 fallback 到 anchor.pictures/videos（保守兜底）。
    /// - 可见 photos/videos 过滤掉 vaild=3，被拒 id 单独存以强制 diff 清；vaild=2 tile 保留（审核中项本身
    ///   就是 picList/latestIcon 里的审核中 mediaUrl，用户看到的就是审核值 —— 已对齐 H5，无需额外处理）
    private static func buildLoadArtifacts(
        check: CheckUserInfoResponse,
        info: UserInfoWithReviewResponse
    ) -> (ReviewStatus, OriginalSnapshot, DraftState) {
        let latestMedia = info.latestIconAndCallVideo ?? []
        let newReview = ReviewStatus(
            nickname: (check.nickname?.isEmpty == false),
            signature: (check.signature?.isEmpty == false),
            avatar: latestMedia.isAvatarReviewing,
            avatarRejected: latestMedia.isAvatarRejected,
            reviewingGreetMsgs: check.greetMsgs ?? []
        )

        let anchor = info.anchorInfo
        let (allPictures, allVideos): ([MediaAsset], [MediaAsset]) = {
            if let picList = info.picList, !picList.isEmpty {
                let photos = picList.filter { $0.mediaType == 1 }.map { Self.mediaAsset(from: $0) }
                let vids = picList.filter { $0.mediaType == 2 }.map { Self.mediaAsset(from: $0) }
                return (photos, vids)
            }
            return (anchor.pictures ?? [], anchor.videos ?? [])
        }()
        let visiblePhotos = allPictures.filter { $0.vaild != 3 }
        let visibleVideos = allVideos.filter { $0.vaild != 3 }
        let hiddenRejectedPhotoIds = allPictures.filter { $0.vaild == 3 }.compactMap(\.assetId)
        let hiddenRejectedVideoIds = allVideos.filter { $0.vaild == 3 }.compactMap(\.assetId)

        // 来电视频：优先 latestIconAndCallVideo 里 businessType=3 && vaild=1；
        // 兜底 anchor.callVideoUrl（若后端只返顶层 URL 无 latestIconAndCallVideo）
        let callVideoMedia: MediaAsset?
        if let m = latestMedia.currentCallVideo {
            callVideoMedia = MediaAsset(
                assetId: m.id, url: m.mediaUrl, coverUrl: nil,
                vaild: m.vaild, createTime: nil
            )
        } else if let url = anchor.callVideoUrl, !url.isEmpty {
            callVideoMedia = MediaAsset(assetId: nil, url: url, coverUrl: nil, vaild: 1, createTime: nil)
        } else {
            callVideoMedia = nil
        }

        let snapshot = OriginalSnapshot(
            nickname: anchor.nickname ?? "",
            avatarUrl: anchor.icon ?? "",
            signature: anchor.signature ?? "",
            photos: visiblePhotos,
            videos: visibleVideos,
            callVideo: callVideoMedia,
            greetMsgs: anchor.greetMsgs ?? [],
            hiddenRejectedPhotoIds: hiddenRejectedPhotoIds,
            hiddenRejectedVideoIds: hiddenRejectedVideoIds
        )

        // 审核中字段：用审核中的提交值填 draft（对齐 H5 L114-115、L80-85）
        // - nickname/signature: check.X 非空 = 审核中 → 用 check.X；否则用 anchor.X
        // - avatar: latestMedia 里 businessType=2 && vaild=2 的 mediaUrl（审核中新头像图）；否则用 anchor.icon
        //   avatarRejected（vaild=3）时保留 anchor.icon 老图（H5 profile/index.vue:85 语义）
        // - greetMsgs/photos/videos/callVideo: 已通过其他机制对齐 H5，无需在 draft 特殊处理
        let draftNickname = (check.nickname?.isEmpty == false) ? (check.nickname ?? "") : snapshot.nickname
        let draftSignature = (check.signature?.isEmpty == false) ? (check.signature ?? "") : snapshot.signature
        let draftAvatarUrl: String = {
            if let reviewingUrl = latestMedia.reviewingAvatarMediaUrl, !reviewingUrl.isEmpty {
                return reviewingUrl
            }
            return snapshot.avatarUrl
        }()

        let newDraft = DraftState(
            nickname: draftNickname,
            avatarUrl: draftAvatarUrl,
            signature: draftSignature,
            photos: snapshot.photos.map(DraftMediaItem.asset),
            videos: snapshot.videos.map(DraftMediaItem.asset),
            callVideo: snapshot.callVideo.map(DraftMediaItem.asset),
            greetMsgs: snapshot.greetMsgs.map(DraftGreetMsg.server)
        )

        return (newReview, snapshot, newDraft)
    }

    /// snapshot → 可编辑 draft 投影（供 applyLoadResult / hydrateFromCache 复用）
    private static func deriveDraft(from snap: OriginalSnapshot) -> DraftState {
        DraftState(
            nickname: snap.nickname,
            avatarUrl: snap.avatarUrl,
            signature: snap.signature,
            photos: snap.photos.map(DraftMediaItem.asset),
            videos: snap.videos.map(DraftMediaItem.asset),
            callVideo: snap.callVideo.map(DraftMediaItem.asset),
            greetMsgs: snap.greetMsgs.map(DraftGreetMsg.server)
        )
    }

    // MARK: - SWR (Stale-While-Revalidate) 缓存优先加载

    /// 从 AnchorInfoStore.info 秒开 4 基础字段（nickname/avatar/signature/greetMsgs）。
    ///
    /// - Returns: true = 命中缓存并进 .editing；false = 缓存缺失，caller 走 `load()` 冷启动
    ///
    /// 只 hydrate 4 个"从 AnchorInfo 可靠获取"的字段。photos/videos/callVideo 不 hydrate：
    /// 1. `AnchorInfo.pictures/videos` 是 iOS 侧臆想 fallback 字段（真接口用 picList）不可信
    /// 2. 缺 vaild 审核态；hydrate 后与 refresh 结果对不齐会视觉抖动
    /// 3. 数组 by-id merge 冲突高风险（Plan agent #3/#5）——不 hydrate 天然规避
    ///
    /// review 全 false 表示"审核态未加载"，View 层此时字段可编辑；refresh 回后若命中审核态
    /// 才切禁用+徽章（接受轻微闪烁，H5 侧同款行为）。
    ///
    /// Store 不直接引用 `AnchorInfoStore.shared`（保持零单例依赖便于测试）；
    /// 数据源由 View 层从 `AnchorInfoStore.shared.info` 传入。
    @discardableResult
    func hydrate(from info: AnchorInfo?) -> Bool {
        guard phase == .loading, originalSnapshot == .empty else { return false }
        guard let info else { return false }

        let snap = OriginalSnapshot(
            nickname: info.nickname ?? "",
            avatarUrl: info.icon ?? "",
            signature: info.signature ?? "",
            photos: [],
            videos: [],
            callVideo: nil,
            greetMsgs: info.greetMsgs ?? [],
            hiddenRejectedPhotoIds: [],
            hiddenRejectedVideoIds: []
        )
        originalSnapshot = snap
        draft = Self.deriveDraft(from: snap)
        review = .none
        phase = .editing
        logger.info("hydrated from cache: greetMsgs=\(snap.greetMsgs.count)")
        return true
    }

    /// 后台拉 checkUserInfo + userInfoWithReview 并合并；不切 .loading。
    ///
    /// - 成功：`mergeRefreshResult` 覆盖 review + 补齐 photos/videos/callVideo
    /// - 失败：仅 warning，不切 .loadError（用户已在编辑，不打断）
    /// - 保护：期间 phase 切成 .saving/.terminated → discard 结果
    /// - 幂等：已有 refreshingTask 则跳过（避免用户快速前后台切换重复触发）
    func refreshInBackground() {
        guard refreshingTask == nil else { return }
        isRefreshing = true
        refreshingTask = Task { @MainActor [weak self] in
            defer {
                self?.isRefreshing = false
                self?.refreshingTask = nil
            }
            guard let self else { return }
            do {
                async let check = self.service.fetchCheckUserInfo()
                async let info = self.service.fetchUserInfoWithReview()
                let (checkResult, infoResult) = try await (check, info)
                // guard phase 未在期间转成 saving/success/terminated
                guard case .editing = self.phase else {
                    logger.info("refresh discarded: phase changed to \(String(describing: self.phase))")
                    return
                }
                self.mergeRefreshResult(check: checkResult, info: infoResult)
                logger.info("SWR refresh merged OK")
            } catch {
                logger.warning("refreshInBackground failed: \(String(describing: error))")
            }
        }
    }

    /// Confirm 前调用：await 后台 refresh 完成，避免把审核中字段一起提交。
    ///
    /// 超时兜底避免用户在网络烂时永远卡住；1.5s 后即使 refresh 未完也放行走 diff
    /// （接受此边界：极烂网 + 缓存 hydrate + Confirm，diff 用 stale review 可能被后端 reject，
    ///  用户看到后端错误提示是可理解的）。
    ///
    /// 实现用轮询（20ms tick）而非 TaskGroup：TaskGroup scope 退出会 await 所有 child tasks，
    /// 而 `Task<Void, Never>.value` 不响应 cancellation → cancelAll 也无法让 refresh task 提前退出。
    func awaitPendingRefresh(timeout: TimeInterval) async {
        guard refreshingTask != nil else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while refreshingTask != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// merge SWR 结果：review 全覆盖；draft 按字段是否审核中 + dirty 判定合并。
    ///
    /// **合并策略**：
    /// - `review`：接口权威，全覆盖
    /// - `nickname/signature/avatar`：
    ///   - 若接口回来是**审核中**（`newReview.X == true`）→ 直接覆盖为审核值（用户无法编辑审核中字段，
    ///     不存在"覆盖用户输入"的问题；此时用户看到的必须是"自己提交审核的新值"，与 H5 对齐）
    ///   - 否则按 dirty check：`draft.X == originalSnapshot.X`（未编辑）→ 同步；否则仅更 snapshot
    /// - `greetMsgs`：draft 无 local 新增且 serverIds 集合与 snapshot 相同（未编辑）→ 整同步；否则仅更 snapshot
    /// - `photos/videos`：hydrate 初值全空，refresh 直接填充 server items（含 vaild=2 审核中项）；
    ///   用户 hydrate 后 addLocal 保留在尾部
    /// - `callVideo`：用户已本地上传（serverId==nil）→ 保留；否则覆盖服务端最新
    private func mergeRefreshResult(check: CheckUserInfoResponse, info: UserInfoWithReviewResponse) {
        let (newReview, newSnapshot, newDraft) = Self.buildLoadArtifacts(check: check, info: info)

        review = newReview

        // nickname/signature/avatar：审核中强制覆盖为审核值（用户不能编辑，无 dirty 保护需求）；
        // 非审核中走 dirty check 保护用户输入
        if newReview.nickname {
            draft.nickname = newDraft.nickname
        } else if draft.nickname == originalSnapshot.nickname {
            draft.nickname = newSnapshot.nickname
        }
        if newReview.avatar {
            draft.avatarUrl = newDraft.avatarUrl
        } else if draft.avatarUrl == originalSnapshot.avatarUrl {
            draft.avatarUrl = newSnapshot.avatarUrl
        }
        if newReview.signature {
            draft.signature = newDraft.signature
        } else if draft.signature == originalSnapshot.signature {
            draft.signature = newSnapshot.signature
        }
        if isGreetMsgsUnedited {
            draft.greetMsgs = newSnapshot.greetMsgs.map(DraftGreetMsg.server)
        }

        // photos/videos：保留用户 local 追加；server items 全用 newSnapshot（含 vaild=2 审核中 tile）
        let userLocalPhotos = draft.photos.filter { $0.serverId == nil }
        draft.photos = newSnapshot.photos.map(DraftMediaItem.asset) + userLocalPhotos

        let userLocalVideos = draft.videos.filter { $0.serverId == nil }
        draft.videos = newSnapshot.videos.map(DraftMediaItem.asset) + userLocalVideos

        // callVideo：用户已本地上传 → 保留；否则覆盖
        if let cur = draft.callVideo, cur.serverId == nil {
            // 保留用户新上传，不覆盖
        } else {
            draft.callVideo = newSnapshot.callVideo.map(DraftMediaItem.asset)
        }

        originalSnapshot = newSnapshot
    }

    /// 判定 greetMsgs 是否未被用户编辑（决定 mergeRefreshResult 覆盖策略）
    private var isGreetMsgsUnedited: Bool {
        guard !draft.greetMsgs.contains(where: { $0.serverId == nil }) else { return false }
        let draftIds = Set(draft.greetMsgs.compactMap(\.serverId))
        let origIds = Set(originalSnapshot.greetMsgs.compactMap(\.serverId))
        return draftIds == origIds
    }

    // MARK: - Field Editing (short text)

    func editNickname(_ text: String) {
        guard phase == .editing, !review.nickname else { return }
        // spec N-7: 超 15 字截断
        draft.nickname = String(text.prefix(EditProfileLimits.nicknameMaxLength))
    }

    func editSignature(_ text: String) {
        guard phase == .editing, !review.signature else { return }
        // spec N-8: 超 200 字截断
        draft.signature = String(text.prefix(EditProfileLimits.signatureMaxLength))
    }

    // MARK: - Avatar (spec §2.6 / N-2)

    /// 头像上传成功后调用（Step 1c 内 uploadImage 完成时触发）
    func markAvatarUploaded(url: String) {
        guard phase == .editing, !review.avatar else { return }
        draft.avatarUrl = url
    }

    // MARK: - Media (photos / videos / callVideo)

    /// 加占位 tile 进 draft（uploadState = .uploading）；供 view 层调
    /// 返回新 tile 的稳定 id
    @discardableResult
    func addPhotoPlaceholder(localId: String = UUID().uuidString) -> String? {
        guard phase == .editing else { return nil }
        // spec N-9: 相册满 9 张不允许再加
        guard draft.photos.count < EditProfileLimits.photosMaxCount else {
            transientToast = .photosLimit
            return nil
        }
        let item = DraftMediaItem.newLocal(localId: localId)
        draft.photos.append(item)
        return item.id
    }

    func markPhotoUploaded(id: String, url: String) {
        updateMediaItem(id: id, in: \.photos) { item in
            item.url = url
            item.uploadState = .idle
        }
    }

    func markPhotoFailed(id: String, message: String) {
        updateMediaItem(id: id, in: \.photos) { $0.uploadState = .failed(message: message) }
    }

    func removePhoto(id: String) {
        guard phase == .editing else { return }
        draft.photos.removeAll { $0.id == id }
    }

    func retryPhoto(id: String) {
        guard phase == .editing,
              let idx = draft.photos.firstIndex(where: { $0.id == id })
        else { return }
        // 重试：state 转 uploading（真上传 task 由 Step 1c 外部触发）
        let newLocalId = UUID().uuidString
        draft.photos[idx].uploadState = .uploading(localId: newLocalId)
    }

    // 视频 / 来电视频 相同模式
    @discardableResult
    func addVideoPlaceholder(localId: String = UUID().uuidString) -> String? {
        guard phase == .editing else { return nil }
        guard draft.videos.count < EditProfileLimits.videosMaxCount else {
            transientToast = .videosLimit
            return nil
        }
        let item = DraftMediaItem.newLocal(localId: localId)
        draft.videos.append(item)
        return item.id
    }

    func markVideoUploaded(id: String, url: String, coverUrl: String? = nil) {
        updateMediaItem(id: id, in: \.videos) {
            $0.url = url
            $0.coverUrl = coverUrl
            $0.uploadState = .idle
        }
    }

    func markVideoFailed(id: String, message: String) {
        updateMediaItem(id: id, in: \.videos) { $0.uploadState = .failed(message: message) }
    }

    func removeVideo(id: String) {
        guard phase == .editing else { return }
        draft.videos.removeAll { $0.id == id }
    }

    func retryVideo(id: String) {
        guard phase == .editing,
              let idx = draft.videos.firstIndex(where: { $0.id == id })
        else { return }
        let newLocalId = UUID().uuidString
        draft.videos[idx].uploadState = .uploading(localId: newLocalId)
    }

    // Call Video (max 1)
    func setCallVideoPlaceholder(localId: String = UUID().uuidString) -> String? {
        guard phase == .editing else { return nil }
        let item = DraftMediaItem.newLocal(localId: localId)
        draft.callVideo = item
        return item.id
    }

    func markCallVideoUploaded(id: String, url: String, coverUrl: String? = nil) {
        guard var v = draft.callVideo, v.id == id else { return }
        v.url = url
        v.coverUrl = coverUrl
        v.uploadState = .idle
        draft.callVideo = v
    }

    func markCallVideoFailed(id: String, message: String) {
        guard var v = draft.callVideo, v.id == id else { return }
        v.uploadState = .failed(message: message)
        draft.callVideo = v
    }

    func clearCallVideo() {
        guard phase == .editing else { return }
        draft.callVideo = nil
    }

    // MARK: - Greet Messages

    func addGreetMsg(content: String) {
        guard phase == .editing else { return }
        let trimmed = String(content.prefix(EditProfileLimits.greetMsgMaxLength))
        guard !trimmed.isEmpty else { return }
        // spec N-23: 允许重复（H5 也允许）
        draft.greetMsgs.append(DraftGreetMsg.newLocal(content: trimmed))
    }

    func removeGreetMsg(id: String) {
        guard phase == .editing else { return }
        draft.greetMsgs.removeAll { $0.id == id }
    }

    // MARK: - Upload Epoch (spec §3.2 / N-20 / N-31)

    /// 上传前调，返回当前 epoch 供 upload task capture
    func beginUpload() -> Int {
        uploadEpoch
    }

    /// upload task 完成时用；老 epoch 不匹配当前 → 丢弃结果（stale）
    func isUploadCurrent(epoch: Int) -> Bool {
        uploadEpoch == epoch
    }

    /// 覆盖上传 / dismiss / 一批 retry 时递增，让老 task 结果被丢弃
    func invalidateOngoingUploads() {
        uploadEpoch += 1
    }

    // MARK: - Confirm

    var canConfirm: Bool {
        phase == .editing
            && !hasUploadingTile
            && !hasFailedTile
    }

    var hasUploadingTile: Bool {
        draft.photos.contains { if case .uploading = $0.uploadState { return true }; return false }
            || draft.videos.contains { if case .uploading = $0.uploadState { return true }; return false }
            || (draft.callVideo.map { if case .uploading = $0.uploadState { return true }; return false } ?? false)
    }

    var hasFailedTile: Bool {
        draft.photos.contains { if case .failed = $0.uploadState { return true }; return false }
            || draft.videos.contains { if case .failed = $0.uploadState { return true }; return false }
            || (draft.callVideo.map { if case .failed = $0.uploadState { return true }; return false } ?? false)
    }

    /// 计算 diff → 有变更调 updateUserInfo；无变更 phase 转 success（view 层 dismiss 无 toast）
    func handleConfirm() async {
        guard phase == .editing else { return }

        // SWR 竞态守护：hydrate 后 200ms 内点 Confirm 时 review 还未加载，
        // 直接 diff 会把审核中字段一起提交被后端 reject。await refresh 完成再走 diff。
        // 1.5s 超时兜底：极烂网下不永久 hang，用户看到后端错误提示是可理解边界。
        await awaitPendingRefresh(timeout: 1.5)
        // await 期间 phase 可能被 sessionInvalidated 打断
        guard phase == .editing else { return }

        // 抢跑守护
        if hasUploadingTile {
            transientToast = .uploading
            return
        }
        if hasFailedTile {
            transientToast = .uploadFailed
            return
        }

        let request = buildUpdateRequest()
        guard let req = request, !req.isEmpty else {
            // 无变更（对齐 H5 handleSubmit L369-374 `router.back()` 无 dialog）：
            // phase 转 .terminated 让 view onChange 触发 dismiss，跳过 alert（spec §5 P-9）
            phase = .terminated
            return
        }

        phase = .saving
        do {
            try await service.updateUserInfo(req)
            // saving 期间可能被 sessionInvalidated 打断 → phase 已 .terminated
            guard phase == .saving else { return }
            phase = .success
        } catch {
            logger.error("updateUserInfo failed: \(String(describing: error))")
            guard phase == .saving else { return }
            phase = .editing
            transientToast = friendlyErrorKey(error)
        }
    }

    // MARK: - Terminated (spec §3.3 / N-33)

    /// SessionStore 挤下线（code 1004/1005）→ apiSessionInvalidated 通知触发
    func handleSessionInvalidated() {
        phase = .terminated
        invalidateOngoingUploads()
    }

    /// Alert Confirm 按下后调用（Step 3 反悔 #3-4：alert 死循环修复）。
    ///
    /// **必须同步**转 phase：SwiftUI `.alert(isPresented:)` binding get() 依据 `phase == .success`，
    /// 若 alert 关闭（用户点 button 或系统自动）后 phase 仍 .success，下一帧 SwiftUI 会检测 get() = true
    /// 再次尝试 present → view 已 detach 触发 "Presenting view controller from detached view controller"
    /// → 死循环。
    ///
    /// 复用 `.terminated`（View onChange 已处理 dismiss）表达"编辑流程完成，view 应关闭"语义。
    func acknowledgeSuccess() {
        if phase == .success {
            phase = .terminated
        }
    }

    // MARK: - Life

    /// view dismiss 时调（onDisappear 内 guard scenePhase != .background）
    func dispose() {
        invalidateOngoingUploads()
    }

    /// spec §3.3 / N-34：view 层 `.onChange(of: scenePhase)` 转发。
    /// - background：记录时戳
    /// - active：若停留 > 60s，把仍在 uploading 的 tile 标 failed（URLSession 已被系统挂起）
    /// - saving 期间后台完成的 alert 由 view 层 `.alert(isPresented: successAlertBinding)` 天然延迟展示
    ///   —— SwiftUI 在 background 不 present alert；回 active 时 binding 重评估自动补弹
    func updateScenePhase(isActive: Bool) {
        if !isActive {
            if enteredBackgroundAt == nil { enteredBackgroundAt = Date() }
            return
        }
        let stayedAt = enteredBackgroundAt
        enteredBackgroundAt = nil
        guard let at = stayedAt,
              Date().timeIntervalSince(at) > Self.backgroundUploadTimeoutSec,
              phase == .editing else { return }
        failStaleUploadingTiles()
    }

    /// 把当前所有 `uploading` 状态的 tile 标 failed（含头像 —— 头像没有 tile 概念，靠 uploadEpoch 递增
    /// 让老 URLSession 回调走 stale guard 分支）
    private func failStaleUploadingTiles() {
        // tile message 是内部技术标记（用户看不到，MediaTile 展示 Retry 按钮而非 message）
        let internalMsg = "upload timeout"
        invalidateOngoingUploads()   // 递增 epoch 让老回调 stale，避免与 markFailed 冲突
        for photo in draft.photos {
            if case .uploading = photo.uploadState {
                markPhotoFailed(id: photo.id, message: internalMsg)
            }
        }
        for video in draft.videos {
            if case .uploading = video.uploadState {
                markVideoFailed(id: video.id, message: internalMsg)
            }
        }
        if let call = draft.callVideo, case .uploading = call.uploadState {
            markCallVideoFailed(id: call.id, message: internalMsg)
        }
        transientToast = .uploadTimeout
    }

    /// view 消费 toast 后 clear（避免重复展示）
    func clearTransientToast() {
        transientToast = nil
    }

    /// View 层触发 toast（审核态点击等场景）
    func showToast(_ key: EditProfileToastKey) {
        transientToast = key
    }

    // MARK: - Uploads (Step 1c 接真 service；Step 1b 骨架已就位)

    /// 头像上传（审核态由 View 层通过条件分支渲染阻止，此处不重复守卫）
    func uploadAvatar(data: Data) async {
        guard phase == .editing, !review.avatar else { return }
        guard data.count <= EditProfileLimits.imageMaxSizeBytes else {
            transientToast = .imageTooLarge
            return
        }
        let epoch = beginUpload()
        do {
            let url = try await service.uploadImage(data: data, preset: .avatar)
            guard isUploadCurrent(epoch: epoch), phase == .editing else { return }
            markAvatarUploaded(url: url)
        } catch {
            guard isUploadCurrent(epoch: epoch), phase == .editing else { return }
            logger.error("uploadAvatar failed: \(String(describing: error))")
            transientToast = friendlyErrorKey(error)
        }
    }

    /// 相册照片上传：先 addPhotoPlaceholder → 拿到 id → 上传成功后 markPhotoUploaded
    func uploadPhoto(data: Data) async {
        guard phase == .editing else { return }
        guard data.count <= EditProfileLimits.imageMaxSizeBytes else {
            transientToast = .imageTooLarge
            return
        }
        guard let tileId = addPhotoPlaceholder() else { return }
        let epoch = beginUpload()
        do {
            let url = try await service.uploadImage(data: data, preset: .moment)
            guard isUploadCurrent(epoch: epoch),
                  draft.photos.contains(where: { $0.id == tileId })
            else { return }
            markPhotoUploaded(id: tileId, url: url)
        } catch {
            guard isUploadCurrent(epoch: epoch),
                  draft.photos.contains(where: { $0.id == tileId })
            else { return }
            logger.error("uploadPhoto failed: \(String(describing: error))")
            markPhotoFailed(id: tileId, message: (error as? APIError)?.message ?? error.localizedDescription)
        }
    }

    /// 相册视频上传
    func uploadVideo(data: Data, fileExtension: String) async {
        guard phase == .editing else { return }
        guard validateVideoInputs(data: data, ext: fileExtension) else { return }
        guard let tileId = addVideoPlaceholder() else { return }
        let epoch = beginUpload()
        do {
            let url = try await service.uploadVideo(data: data, fileExtension: fileExtension)
            guard isUploadCurrent(epoch: epoch),
                  draft.videos.contains(where: { $0.id == tileId })
            else { return }
            markVideoUploaded(id: tileId, url: url)
        } catch {
            guard isUploadCurrent(epoch: epoch),
                  draft.videos.contains(where: { $0.id == tileId })
            else { return }
            logger.error("uploadVideo failed: \(String(describing: error))")
            markVideoFailed(id: tileId, message: (error as? APIError)?.message ?? error.localizedDescription)
        }
    }

    /// 来电视频上传（max 1，覆盖上传时先清）
    func uploadCallVideo(data: Data, fileExtension: String) async {
        guard phase == .editing else { return }
        guard validateVideoInputs(data: data, ext: fileExtension) else { return }
        // 若已有旧的 uploading，先递增 epoch 让它 stale
        if draft.callVideo != nil {
            invalidateOngoingUploads()
        }
        guard let tileId = setCallVideoPlaceholder() else { return }
        let epoch = beginUpload()
        do {
            let url = try await service.uploadVideo(data: data, fileExtension: fileExtension)
            guard isUploadCurrent(epoch: epoch),
                  draft.callVideo?.id == tileId
            else { return }
            markCallVideoUploaded(id: tileId, url: url)
        } catch {
            guard isUploadCurrent(epoch: epoch),
                  draft.callVideo?.id == tileId
            else { return }
            logger.error("uploadCallVideo failed: \(String(describing: error))")
            markCallVideoFailed(id: tileId, message: (error as? APIError)?.message ?? error.localizedDescription)
        }
    }

    /// 视频前置校验：大小 + 扩展名
    private func validateVideoInputs(data: Data, ext: String) -> Bool {
        guard data.count <= EditProfileLimits.videoMaxSizeBytes else {
            transientToast = .videoTooLarge
            return false
        }
        let normalizedExt = ext.lowercased()
        guard EditProfileLimits.allowedVideoExtensions.contains(normalizedExt) else {
            transientToast = .videoFormatUnsupported
            return false
        }
        return true
    }

    // MARK: - Derived (审核态派生)

    var canEditNickname: Bool { !review.nickname }
    var canEditSignature: Bool { !review.signature }
    var canEditAvatar: Bool { !review.avatar }

    // MARK: - Diff (智能字段检测；对齐 H5 handleSubmit L253-374)

    func buildUpdateRequest() -> UpdateUserInfoRequest? {
        var req = UpdateUserInfoRequest()

        // 昵称：变化 且 非审核中
        if draft.nickname != originalSnapshot.nickname, !review.nickname {
            req.nickname = draft.nickname
        }

        // 头像
        if draft.avatarUrl != originalSnapshot.avatarUrl, !review.avatar {
            req.icon = draft.avatarUrl
        }

        // 简介
        if draft.signature != originalSnapshot.signature, !review.signature {
            req.signature = draft.signature
        }

        // Photos：新增 URL + 删除 id（含 vaild=3 强制清）
        let newPhotoUrls = draft.photos
            .filter { $0.serverId == nil }
            .map(\.url)
            .filter { !$0.isEmpty }
        let draftPhotoServerIds = Set(draft.photos.compactMap(\.serverId))
        var picsDel = originalSnapshot.photos
            .compactMap(\.assetId)
            .filter { !draftPhotoServerIds.contains($0) }
        picsDel.append(contentsOf: originalSnapshot.hiddenRejectedPhotoIds)
        picsDel = Array(Set(picsDel))  // 去重

        if !newPhotoUrls.isEmpty { req.pics = newPhotoUrls }
        if !picsDel.isEmpty { req.picsDel = picsDel }

        // Videos：同 photos
        let newVideoUrls = draft.videos
            .filter { $0.serverId == nil }
            .map(\.url)
            .filter { !$0.isEmpty }
        let draftVideoServerIds = Set(draft.videos.compactMap(\.serverId))
        var videosDel = originalSnapshot.videos
            .compactMap(\.assetId)
            .filter { !draftVideoServerIds.contains($0) }
        videosDel.append(contentsOf: originalSnapshot.hiddenRejectedVideoIds)
        videosDel = Array(Set(videosDel))

        if !newVideoUrls.isEmpty { req.videos = newVideoUrls }
        if !videosDel.isEmpty { req.videosDel = videosDel }

        // Call Video：draft 与 original 对比
        let origCallId = originalSnapshot.callVideo?.assetId
        switch (draft.callVideo, origCallId) {
        case (let cur?, let oId?) where cur.serverId == nil:
            // 新上传：设新 URL + 删旧 id
            if !cur.url.isEmpty { req.callVideoUrl = cur.url }
            req.callVideosDel = [oId]
        case (nil, let oId?):
            // 用户清空来电视频
            req.callVideosDel = [oId]
        case (let cur?, nil) where cur.serverId == nil:
            // 原来无，新上传
            if !cur.url.isEmpty { req.callVideoUrl = cur.url }
        default:
            break
        }

        // GreetMsgs：新增（无 serverId 的 content）+ 删除（原有 - draft 现存的 serverId）
        let newGreetContents = draft.greetMsgs
            .filter { $0.serverId == nil }
            .map(\.content)
            .filter { !$0.isEmpty }
        let draftGreetServerIds = Set(draft.greetMsgs.compactMap(\.serverId))
        let delGreetIds = originalSnapshot.greetMsgs
            .compactMap(\.serverId)
            .filter { !draftGreetServerIds.contains($0) }

        if !newGreetContents.isEmpty { req.addGreetList = newGreetContents }
        if !delGreetIds.isEmpty { req.delGreetList = delGreetIds }

        return req.isEmpty ? nil : req
    }

    // MARK: - Helpers

    private func updateMediaItem(
        id: String,
        in keyPath: WritableKeyPath<DraftState, [DraftMediaItem]>,
        _ mutate: (inout DraftMediaItem) -> Void
    ) {
        guard let idx = draft[keyPath: keyPath].firstIndex(where: { $0.id == id }) else { return }
        var item = draft[keyPath: keyPath][idx]
        mutate(&item)
        draft[keyPath: keyPath][idx] = item
    }

    /// 生成 View 层可翻译的 toast key
    private func friendlyErrorKey(_ error: Error) -> EditProfileToastKey {
        if let api = error as? APIError {
            return .apiError(code: api.code, message: api.message)
        }
        return .networkError
    }

    /// PicListItem → MediaAsset（Step 3 反悔 #3-3：picList 分流为 photos/videos 时用）
    fileprivate static func mediaAsset(from item: UserInfoWithReviewResponse.PicListItem) -> MediaAsset {
        MediaAsset(
            assetId: item.id,
            url: item.mediaUrl,
            coverUrl: item.coverUrl,
            vaild: item.vaild,
            createTime: nil
        )
    }
}

#if DEBUG
/// Preview 专用直写状态（bypass `private(set)`）。
/// 同文件 extension 才能写 `private(set)` 字段（Swift access rule）。
/// 生产代码禁用；仅 EditProfileView+Preview.swift 调用。
extension EditProfileStore {
    func _previewApply(
        phase: EditProfilePhase,
        draft: DraftState,
        review: ReviewStatus,
        snapshot: OriginalSnapshot,
        loadErrorMessage: String? = nil,
        transientToast: EditProfileToastKey? = nil
    ) {
        self.phase = phase
        self.draft = draft
        self.review = review
        self.originalSnapshot = snapshot
        self.loadErrorMessage = loadErrorMessage
        self.transientToast = transientToast
    }
}
#endif
