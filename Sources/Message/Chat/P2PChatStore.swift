import Combine
import Foundation

/// P2P 私聊页 store（H-2 spec §2.1）。
///
/// **责任**：
/// - 单会话历史拉取（首屏 20 + 上拉 20/页）
/// - 乐观发送 + 状态机迁移（sending → uploading → sent → read；失败 → failed/refused）
/// - SDK 增量事件合并（messageId 去重；loading 期入 pendingUpdates，loaded 后合并 —— 复用 H-1 模式）
/// - 已读回执（进页 + 收新消息且在底部时）
/// - 发送成功后主动 emit `MessageSessionStore.shared` update 让会话列表 lastMessage 联动（spec §4.2 red team #6）
///
/// **生命周期**：`@StateObject` on `ChatDetailView`；单 store 单 peer（换 peer 需重建）。
///
/// **零 SDK 依赖**：完全走 `P2PChatProviderProtocol` + `MessageSessionStore.shared`（后者是 protocol 抽象）。
@MainActor
final class P2PChatStore: ObservableObject {

    // MARK: - 对外状态

    @Published private(set) var state: P2PChatState = .loading

    /// 是否已滚到最旧一条（上拉停止）
    @Published private(set) var isEndReached: Bool = false

    /// 上拉分页 loading 中（UI 显示底部 spinner）
    @Published private(set) var isLoadingMore: Bool = false

    /// 未在底部时新消息 badge 计数
    @Published private(set) var pendingBottomBadge: Int = 0

    // MARK: - 输入

    /// 对端 yxAccId（会话唯一标识）
    let peerYxAccId: String

    /// 我方 yxAccId（判定 isOutgoing 用）
    let selfYxAccId: String

    // MARK: - 依赖

    private let provider: P2PChatProviderProtocol
    /// H-3 私密消息前置签发（spec Critical-2）；H-2 兼容路径 nil，Store 不支持 sendPrivate
    private let sendPrivateInfoService: SendPrivateInfoServiceProtocol?
    /// 每页条数（spec §4.6 = 20）
    private let pageSize: Int
    /// Batch 6.2a：回复积分 4 tip L10n 文案（caller 传入,Store 转发给 ReplyPointsStore.onReceiveUserMsg 触发 stimulate tip）
    /// nil = 不触发回复积分接线（HilyTests / customer / system 会话场景兼容）
    private let replyPointsTipTexts: ReplyPointsTipTexts?
    /// P2P 的总权限闸门。生产默认接 `SelfPermissionBridge`；测试可注入 fake。
    private let directMessagesGate: (String) -> Bool
    /// `false` 在权限桥启动绑定前仅代表未知，不应把正常账号的 Store 永久撤销。
    private let isDirectMessagesPermissionResolved: () -> Bool
    /// 权限撤销时由 publisher 主动停订阅和清内存态，不能只依赖 View 从层级移除。
    private var directMessagesPermissionCancellable: AnyCancellable?

    // MARK: - 内部态

    /// loading 期入队 delegate 事件，loaded 后合并（复用 H-1 pendingUpdates 模式；spec §4.5 red team #10）
    private var pendingEvents: [P2PChatEvent] = []
    /// 客户端 → 服务端 messageId 映射（发送完成时用于将乐观 message 替换为真 message）
    private var clientToServerId: [String: String] = [:]
    /// 埋点去重：SDK completion 与 async send 返回可能先后各到一次，业务成功事件只能报一次。
    private var analyticsSentMessageIds: Set<String> = []
    private var analyticsFirstReplyIncomingIds: Set<String> = []
    /// 该 Store 绑定单个会话。动态撤权后永久失效，重新授权必须新建会话页，避免旧消息和旧 SDK 回调复活。
    private var isDirectMessagesAccessRevoked = false

    // MARK: - init / teardown

    init(peerYxAccId: String,
         selfYxAccId: String,
         provider: P2PChatProviderProtocol,
         sendPrivateInfoService: SendPrivateInfoServiceProtocol? = nil,
         pageSize: Int = 20,
         replyPointsTipTexts: ReplyPointsTipTexts? = nil,
         directMessagesGate: ((String) -> Bool)? = nil,
         isDirectMessagesPermissionResolved: (() -> Bool)? = nil,
         directMessagesPublisher: AnyPublisher<Bool, Never>? = nil,
         directMessagesLoadedPublisher: AnyPublisher<Bool, Never>? = nil) {
        // Default argument expressions are evaluated outside this @MainActor initializer. Resolve
        // bridge-backed defaults here so Swift's actor isolation remains intact.
        let resolvedGate = directMessagesGate ?? Self.defaultDirectMessagesGate
        let resolvedPermissionState = isDirectMessagesPermissionResolved
            ?? Self.defaultDirectMessagesPermissionResolved
        let resolvedPublisher = directMessagesPublisher ?? Self.defaultDirectMessagesPublisher
        let resolvedLoadedPublisher: AnyPublisher<Bool, Never>?
        if directMessagesPublisher == nil {
            resolvedLoadedPublisher = directMessagesLoadedPublisher
                ?? Self.defaultDirectMessagesLoadedPublisher
        } else {
            resolvedLoadedPublisher = directMessagesLoadedPublisher
        }

        self.peerYxAccId = peerYxAccId
        self.selfYxAccId = selfYxAccId
        self.provider = provider
        self.sendPrivateInfoService = sendPrivateInfoService
        self.pageSize = pageSize
        self.replyPointsTipTexts = replyPointsTipTexts
        self.directMessagesGate = resolvedGate
        self.isDirectMessagesPermissionResolved = resolvedPermissionState

        provider.subscribe { [weak self] event in
            self?.handleEvent(event)
        }
        if resolvedPermissionState(),
           !resolvedGate("p2pSubscribe") {
            revokeDirectMessagesAccess()
        }
        if let resolvedPublisher {
            let loadedPublisher = resolvedLoadedPublisher
                ?? Just(true).eraseToAnyPublisher()
            directMessagesPermissionCancellable = loadedPublisher
                .combineLatest(resolvedPublisher)
                .removeDuplicates(by: Self.sameDirectMessagesPermission)
                .sink { [weak self] loaded, allowed in
                    guard loaded, !allowed else { return }
                    self?.revokeDirectMessagesAccess()
                }
        }
    }

    /// H-2 spec §4.8 red team #8：view 层 `onDisappear + scenePhase 守卫` 显式调用解 delegate 订阅。
    /// 不放 deinit —— `provider.unsubscribe()` 是 @MainActor 方法，deinit 隔离语义不保证。
    func teardown() {
        provider.unsubscribe()
    }

    /// 供容器在依赖首屏历史的后续逻辑（回复积分 hydrate / 私密状态校验）前等待加载结束。
    /// `ChatDetailView.task` 与 `ChatDetailContainer.task` 同时启动，不能假设二者先后顺序。
    func waitForInitialLoad() async {
        guard requireDirectMessages(action: "p2pWaitForInitialLoad") else { return }
        while case .loading = state {
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
        }
    }

    // MARK: - 私密消息 lockStatus 批量应用（对齐 H5 chat/index.vue checkPrivateInfo）

    /// 收集当前 state 里的 private 消息 privateId 集合(caller 传给 CheckPrivateInfoService)。
    /// 空数组 → caller 跳过打网。
    var currentPrivateMessageIds: [String] {
        guard case .loaded(let msgs) = state else { return [] }
        return msgs.compactMap { m -> String? in
            guard let pid = m.privateId, !pid.isEmpty else { return nil }
            switch m.content {
            case .privateImage, .privateVideo: return pid
            default: return nil
            }
        }
    }

    /// 用 checkPrivateInfo 返回的 lockStatus 批量更新私密消息。
    /// - 未命中的 privateId → 保持原 lockStatus(可能是 .unknown)
    /// - 命中但 lockStatus 未变 → 短路(避免无谓 state 重赋)
    /// `ChatMessage.content` 是 `let`,更新走 struct 完整重建(保留 status/chatBubble/privateId 等 var 字段)。
    func applyPrivateLockStatuses(_ statuses: [String: PrivateLockStatus]) {
        guard requireDirectMessages(action: "p2pApplyPrivateLockStatuses") else { return }
        guard case .loaded(let current) = state, !statuses.isEmpty else { return }
        var changed = false
        let updated = current.map { m -> ChatMessage in
            guard let pid = m.privateId, let newStatus = statuses[pid] else { return m }
            let newContent: ChatMessageContent
            switch m.content {
            case .privateImage(let url, let lockStatus):
                guard lockStatus != newStatus else { return m }
                newContent = .privateImage(url: url, lockStatus: newStatus)
            case .privateVideo(let url, let cover, let dur, let lockStatus):
                guard lockStatus != newStatus else { return m }
                newContent = .privateVideo(url: url, coverUrl: cover, dur: dur, lockStatus: newStatus)
            default:
                return m
            }
            changed = true
            var rebuilt = ChatMessage(
                id: m.id, clientMsgId: m.clientMsgId,
                from: m.from, to: m.to,
                content: newContent, status: m.status,
                timestamp: m.timestamp, isOutgoing: m.isOutgoing
            )
            rebuilt.chatBubble = m.chatBubble
            rebuilt.privateId = m.privateId
            return rebuilt
        }
        if changed { state = .loaded(updated) }
    }

    // MARK: - 加载

    /// 首屏 load + markAllRead + sendReceipt(最新非我消息)。
    func load() async {
        guard requireDirectMessages(action: "p2pLoad") else { return }
        state = .loading
        pendingEvents.removeAll()

        do {
            let msgs = try await provider.fetchHistory(peerYxAccId: peerYxAccId, anchor: nil, limit: pageSize)
            guard requireDirectMessages(action: "p2pLoadAfterHistory") else { return }
            // 空态判定：空数组 → .empty（新会话）；否则合并 pending 事件后进 .loaded
            if msgs.isEmpty {
                state = .empty
                guard requireDirectMessages(action: "p2pMarkAllRead") else { return }
                await provider.markAllRead(peerYxAccId: peerYxAccId)
                pendingEvents.removeAll()
                return
            }

            // 合并 loading 期入队事件
            var merged = msgs
            for event in pendingEvents {
                merged = applyEventLocally(event, to: merged)
            }
            pendingEvents.removeAll()
            state = .loaded(merged)
            isEndReached = merged.count < pageSize

            // P1-2：load 成功后从历史消息 hydrate ReplyPointsStore.lastUserMsgInfo，
            // 对齐 H5 initReplyRemindOnEnter。beginSession 未完成时 hydrate 内部 guard 跳过。
            if let tipTexts = replyPointsTipTexts {
                ReplyPointsStore.shared.hydrateLastUserMsgFromHistory(
                    peer: peerYxAccId,
                    msgs: merged,
                    tipTexts: tipTexts
                )
            }

            // 进页副作用：清本地 unread + 给对端已读回执（最后一条非我消息）
            guard requireDirectMessages(action: "p2pMarkAllRead") else { return }
            await provider.markAllRead(peerYxAccId: peerYxAccId)
            if let lastIncoming = merged.last(where: { !$0.isOutgoing }) {
                guard requireDirectMessages(action: "p2pInitialReceipt") else { return }
                await provider.sendReceipt(peerYxAccId: peerYxAccId, lastReceivedMessageId: lastIncoming.id)
            }
        } catch {
            guard requireDirectMessages(action: "p2pLoadError") else { return }
            state = .error(String(describing: error))
        }
    }

    /// 上拉加载 20 条。anchor 用当前最旧一条的 messageId。
    func loadMore() async {
        guard requireDirectMessages(action: "p2pLoadMore") else { return }
        guard case .loaded(let current) = state,
              !isEndReached,
              !isLoadingMore,
              let oldest = current.first else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let older = try await provider.fetchHistory(peerYxAccId: peerYxAccId, anchor: oldest.id, limit: pageSize)
            guard requireDirectMessages(action: "p2pLoadMoreAfterHistory") else { return }
            if older.isEmpty {
                isEndReached = true
                return
            }
            // messageId 去重后 prepend
            let existing = Set(current.map(\.id))
            let deduped = older.filter { !existing.contains($0.id) }
            state = .loaded(deduped + current)
            isEndReached = older.count < pageSize
        } catch {
            guard requireDirectMessages(action: "p2pLoadMoreError") else { return }
            // 上拉失败仅 log，不切 state.error（保留已有历史）
        }
    }

    /// 重试（用户点错误页重试按钮）
    func retry() async {
        guard requireDirectMessages(action: "p2pRetry") else { return }
        await load()
    }

    // MARK: - 发送（乐观 + 状态机迁移）

    /// 发文字消息（H-2 spec §4.2）。
    func sendText(_ text: String) async {
        guard requireDirectMessages(action: "p2pSendText") else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let clientMsgId = UUID().uuidString
        let now = currentTimestampMs()
        // Batch 3.9：我方 optimistic 消息带主播自己穿戴的 chatBubble URL（TextBubbleView 用 NinePatchImageView 渲染背景）
        var optimistic = ChatMessage(
            id: clientMsgId, clientMsgId: clientMsgId,
            from: selfYxAccId, to: peerYxAccId,
            content: .text(trimmed),
            status: .sending,
            timestamp: now,
            isOutgoing: true
        )
        #if !HILY_TESTS
        // AnchorInfoStore.shared 依赖 Profile 模块非 test 编译面（Codable model + 服务）；tests 隔离屏蔽
        optimistic.chatBubble = AnchorInfoStore.shared.currentChatBubble.flatMap(URL.init(string:))
        #endif
        appendOptimistic(optimistic)

        do {
            let messageId = try await provider.sendText(peerYxAccId: peerYxAccId, text: trimmed, clientMsgId: clientMsgId)
            guard requireDirectMessages(action: "p2pSendTextCompleted") else { return }
            finalizeSending(clientMsgId: clientMsgId, messageId: messageId, error: nil)
        } catch let e as SendError {
            guard requireDirectMessages(action: "p2pSendTextError") else { return }
            finalizeSending(clientMsgId: clientMsgId, messageId: nil, error: e)
        } catch {
            guard requireDirectMessages(action: "p2pSendTextError") else { return }
            finalizeSending(clientMsgId: clientMsgId, messageId: nil, error: .retryable(errorCode: nil))
        }
    }

    /// 发音频消息（H-2 spec §4.3）。
    /// - Parameters:
    ///   - localFilePath: 已 copy 到 chat 目录持久化的音频路径
    ///   - dur: 秒数
    func sendAudio(localFilePath: String, dur: Int, previewURL: URL) async {
        guard requireDirectMessages(action: "p2pSendAudio") else { return }
        guard dur >= 1 else { return }
        let clientMsgId = UUID().uuidString
        let now = currentTimestampMs()
        appendOptimistic(ChatMessage(
            id: clientMsgId, clientMsgId: clientMsgId,
            from: selfYxAccId, to: peerYxAccId,
            content: .audio(url: previewURL, dur: dur),
            status: .uploading(progress: 0),
            timestamp: now,
            isOutgoing: true
        ))

        do {
            let messageId = try await provider.sendAudio(peerYxAccId: peerYxAccId, localFilePath: localFilePath, dur: dur, clientMsgId: clientMsgId)
            guard requireDirectMessages(action: "p2pSendAudioCompleted") else { return }
            finalizeSending(clientMsgId: clientMsgId, messageId: messageId, error: nil)
        } catch let e as SendError {
            guard requireDirectMessages(action: "p2pSendAudioError") else { return }
            finalizeSending(clientMsgId: clientMsgId, messageId: nil, error: e)
        } catch {
            guard requireDirectMessages(action: "p2pSendAudioError") else { return }
            finalizeSending(clientMsgId: clientMsgId, messageId: nil, error: .retryable(errorCode: "upload"))
        }
    }

    /// 发图片消息（H-2 spec §4.4 主路径：外链免上传）。
    func sendImage(item: AnchorMediaItem) async {
        guard requireDirectMessages(action: "p2pSendImage") else { return }
        let clientMsgId = UUID().uuidString
        let now = currentTimestampMs()
        appendOptimistic(ChatMessage(
            id: clientMsgId, clientMsgId: clientMsgId,
            from: selfYxAccId, to: peerYxAccId,
            content: .image(url: item.mediaUrl, size: nil),
            status: .sending,
            timestamp: now,
            isOutgoing: true
        ))

        do {
            let messageId = try await provider.sendImage(peerYxAccId: peerYxAccId, url: item.mediaUrl, clientMsgId: clientMsgId)
            guard requireDirectMessages(action: "p2pSendImageCompleted") else { return }
            finalizeSending(clientMsgId: clientMsgId, messageId: messageId, error: nil)
        } catch let e as SendError {
            guard requireDirectMessages(action: "p2pSendImageError") else { return }
            finalizeSending(clientMsgId: clientMsgId, messageId: nil, error: e)
        } catch {
            guard requireDirectMessages(action: "p2pSendImageError") else { return }
            finalizeSending(clientMsgId: clientMsgId, messageId: nil, error: .retryable(errorCode: nil))
        }
    }

    // MARK: - H-3 私密消息发送（spec §4.1 / Critical-2）

    /// 发私密图片消息。
    /// **前置**：调 `sendPrivateInfoService.fetchSignedData(peerUserId, privateId)` 拿后端签发 data。
    /// **caller (ChatDetailContainer)** 从 `GiftMessageService.fetchList` 拉私密相册 → 用户选一项 →
    /// 转 `PrivateMediaSelection` → 调用本方法。
    func sendPrivateImage(peerUserId: String, media: PrivateMediaSelection) async {
        guard requireDirectMessages(action: "p2pSendPrivateImage"),
              media.iconType == 1,
              Self.canSendPrivateMedia(action: "sendPrivateImage") else { return }
        guard let sendPrivateService = self.sendPrivateInfoService else {
            // service 未注入 —— H-2 兼容路径不该走到；ChatDetailContainer 层保证注入
            return
        }
        let clientMsgId = UUID().uuidString
        let now = currentTimestampMs()
        var optimistic = ChatMessage(
            id: clientMsgId, clientMsgId: clientMsgId,
            from: selfYxAccId, to: peerYxAccId,
            content: .privateImage(url: media.url, lockStatus: .unknown),
            status: .sending,
            timestamp: now,
            isOutgoing: true
        )
        optimistic.privateId = media.privateId
        appendOptimistic(optimistic)

        do {
            let signedData = try await sendPrivateService.fetchSignedData(peerUserId: peerUserId, privateId: media.privateId)
            guard requireDirectMessages(action: "p2pSendPrivateImageAfterSign"),
                  Self.canSendPrivateMedia(action: "sendPrivateImage") else {
                removeMessage(clientMsgId: clientMsgId)
                return
            }
            let messageId = try await provider.sendPrivateImage(
                peerYxAccId: peerYxAccId, peerUserId: peerUserId, url: media.url,
                privateId: media.privateId, signedData: signedData, clientMsgId: clientMsgId
            )
            finalizeSending(clientMsgId: clientMsgId, messageId: messageId, error: nil)
            trackPrivateMediaSend(type: "photo", price: media.giftPrice)
        } catch let e as SendError {
            guard requireDirectMessages(action: "p2pSendPrivateImageError") else { return }
            finalizeSending(clientMsgId: clientMsgId, messageId: nil, error: e)
        } catch {
            guard requireDirectMessages(action: "p2pSendPrivateImageError") else { return }
            // sendPrivateInfo 失败 or NIM SDK 非 SendError → 归类 retryable
            finalizeSending(clientMsgId: clientMsgId, messageId: nil, error: .retryable(errorCode: "signPrivate"))
        }
    }

    /// 发私密视频消息（结构同 sendPrivateImage；lockStatus 初始 .unknown；解密播放由 GiftMessageService.decryptVideoUrl 复用）。
    func sendPrivateVideo(peerUserId: String, media: PrivateMediaSelection) async {
        guard requireDirectMessages(action: "p2pSendPrivateVideo"),
              media.iconType == 2,
              Self.canSendPrivateMedia(action: "sendPrivateVideo") else { return }
        guard let sendPrivateService = self.sendPrivateInfoService else { return }

        let clientMsgId = UUID().uuidString
        let now = currentTimestampMs()
        var optimistic = ChatMessage(
            id: clientMsgId, clientMsgId: clientMsgId,
            from: selfYxAccId, to: peerYxAccId,
            content: .privateVideo(url: media.url, coverUrl: media.coverUrl, dur: media.dur ?? 0, lockStatus: .unknown),
            status: .sending,
            timestamp: now,
            isOutgoing: true
        )
        optimistic.privateId = media.privateId
        appendOptimistic(optimistic)

        do {
            let signedData = try await sendPrivateService.fetchSignedData(peerUserId: peerUserId, privateId: media.privateId)
            guard requireDirectMessages(action: "p2pSendPrivateVideoAfterSign"),
                  Self.canSendPrivateMedia(action: "sendPrivateVideo") else {
                removeMessage(clientMsgId: clientMsgId)
                return
            }
            let messageId = try await provider.sendPrivateVideo(
                peerYxAccId: peerYxAccId, peerUserId: peerUserId, url: media.url,
                thumbnailUrl: media.coverUrl, dur: media.dur ?? 0,
                privateId: media.privateId, signedData: signedData, clientMsgId: clientMsgId
            )
            finalizeSending(clientMsgId: clientMsgId, messageId: messageId, error: nil)
            trackPrivateMediaSend(type: "video", price: media.giftPrice)
        } catch let e as SendError {
            guard requireDirectMessages(action: "p2pSendPrivateVideoError") else { return }
            finalizeSending(clientMsgId: clientMsgId, messageId: nil, error: e)
        } catch {
            guard requireDirectMessages(action: "p2pSendPrivateVideoError") else { return }
            finalizeSending(clientMsgId: clientMsgId, messageId: nil, error: .retryable(errorCode: "signPrivate"))
        }
    }

    /// 发视频消息（H-2 spec §4.4）。
    func sendVideo(item: AnchorMediaItem) async {
        guard requireDirectMessages(action: "p2pSendVideo") else { return }
        let clientMsgId = UUID().uuidString
        let now = currentTimestampMs()
        appendOptimistic(ChatMessage(
            id: clientMsgId, clientMsgId: clientMsgId,
            from: selfYxAccId, to: peerYxAccId,
            content: .video(url: item.mediaUrl, thumbnail: item.coverUrl, dur: item.dur ?? 0),
            status: .sending,
            timestamp: now,
            isOutgoing: true
        ))

        do {
            let messageId = try await provider.sendVideo(peerYxAccId: peerYxAccId, url: item.mediaUrl, thumbnailUrl: item.coverUrl, dur: item.dur ?? 0, clientMsgId: clientMsgId)
            guard requireDirectMessages(action: "p2pSendVideoCompleted") else { return }
            finalizeSending(clientMsgId: clientMsgId, messageId: messageId, error: nil)
        } catch let e as SendError {
            guard requireDirectMessages(action: "p2pSendVideoError") else { return }
            finalizeSending(clientMsgId: clientMsgId, messageId: nil, error: e)
        } catch {
            guard requireDirectMessages(action: "p2pSendVideoError") else { return }
            finalizeSending(clientMsgId: clientMsgId, messageId: nil, error: .retryable(errorCode: nil))
        }
    }

    /// 重发失败消息（用户 tap 红叹号触发）。
    /// **仅** `.failed` 可重发；`.refused` 拒绝（UI 层应隐藏红叹号）。
    func resend(clientMsgId: String) async {
        guard requireDirectMessages(action: "p2pResend") else { return }
        guard case .loaded(let msgs) = state,
              let msg = msgs.first(where: { $0.clientMsgId == clientMsgId }) else { return }
        // 重发前先删掉旧的失败消息，再走一遍发送流程
        removeMessage(clientMsgId: clientMsgId)
        switch msg.content {
        case .text(let t):
            await sendText(t)
        case .image(let url, _):
            await sendImage(item: AnchorMediaItem(id: clientMsgId, mediaUrl: url, coverUrl: nil, kind: .image, dur: nil))
        case .video(let url, let cover, let dur):
            await sendVideo(item: AnchorMediaItem(id: clientMsgId, mediaUrl: url, coverUrl: cover, kind: .video, dur: dur))
        default:
            // .audio: 重发需 caller 传 localFilePath，Store 无法直接重发；UI 走 VoiceRecorder 缓存路径
            // .systemGift / .missedCall / .systemTip / .system: 服务端/系统消息不重发
            // H-3: .privateImage / .privateVideo 不走 resend 路径（需重新 apiGetSendPrivateInfo 前置签发；用户回 Private tab 选发）
            // H-3: .chatTip 是本地注入的 UI 提示，无发送态
            break
        }
    }

    // MARK: - 底部 badge 处理

    /// UI 在滚到底部或用户主动清除时调
    func markBottomReached() {
        pendingBottomBadge = 0
    }

    // MARK: - Delegate 事件（NIMChatAdapter → @MainActor）

    func handleEvent(_ event: P2PChatEvent) {
        guard requireDirectMessages(action: "p2pHandleEvent") else { return }
        // loading 期入队
        if case .loading = state {
            pendingEvents.append(event)
            return
        }
        applyEvent(event)
    }

    private func applyEvent(_ event: P2PChatEvent) {
        switch event {
        case .received(let incoming):
            handleReceived(incoming)
        case .sendingProgress(let clientMsgId, let progress):
            updateStatus(clientMsgId: clientMsgId) { current in
                if case .uploading = current { return .uploading(progress: progress) }
                return current
            }
        case .sendingCompleted(let clientMsgId, let messageId, let error):
            finalizeSending(clientMsgId: clientMsgId, messageId: messageId, error: error)
        case .receiptReceived(let timestamp):
            handleReceipt(upToTimestamp: timestamp)
        }
    }

    private func handleReceived(_ incoming: [ChatMessage]) {
        guard case .loaded(let current) = state else {
            // .empty 状态收增量 → 升级到 .loaded
            if case .empty = state, !incoming.isEmpty {
                state = .loaded(incoming)
                // 收到对端新消息 → 立即回执 + badge（视为 view 已 active）
                if let last = incoming.last(where: { !$0.isOutgoing }) {
                    sendReceiptIfAllowed(lastReceivedMessageId: last.id)
                }
                pendingBottomBadge += incoming.count
            }
            return
        }

        let existing = Set(current.map(\.id))
        let deduped = incoming.filter { !existing.contains($0.id) }
        guard !deduped.isEmpty else { return }
        state = .loaded(current + deduped)
        pendingBottomBadge += deduped.count

        // 收到对端新消息 → 已读回执给对端
        if let lastIncoming = deduped.last(where: { !$0.isOutgoing }) {
            sendReceiptIfAllowed(lastReceivedMessageId: lastIncoming.id)
        }

        // Batch 6.2a：对端消息累加回复积分进度 + 触发 stimulate tip
        // 对齐 H5 chat/index.vue:172-181 handlePayMsg（收到对端消息且非礼物触发进度累加）
        #if !HILY_TESTS
        triggerReceiveReplyPoints(for: deduped)
        #endif
    }

    /// Batch 6.2a：把 deduped incoming 消息中的对端非礼物消息喂给 ReplyPointsStore.onReceiveUserMsg
    private func triggerReceiveReplyPoints(for deduped: [ChatMessage]) {
        guard let tipTexts = replyPointsTipTexts else { return }
        for m in deduped where !m.isOutgoing {
            let isGift: Bool
            if case .systemGift = m.content { isGift = true } else { isGift = false }
            ReplyPointsStore.shared.onReceiveUserMsg(
                peer: peerYxAccId,
                msgId: m.id,
                timestamp: m.timestamp,
                msgType: m.msgType,   // P1-1：Mapper 从 remoteExt.msgType 提取；缺失时 Store 兜底 "pay"
                isGift: isGift,
                stimulateTipText: tipTexts.stimulate
            )
        }
    }

    private func handleReceipt(upToTimestamp: Int64) {
        guard case .loaded(let current) = state else { return }
        var changed = false
        let updated = current.map { msg -> ChatMessage in
            guard msg.isOutgoing,
                  case .sent = msg.status,
                  msg.timestamp <= upToTimestamp else { return msg }
            changed = true
            var m = msg; m.status = .read; return m
        }
        if changed { state = .loaded(updated) }
    }

    private func sendReceiptIfAllowed(lastReceivedMessageId: String) {
        Task { @MainActor [weak self] in
            guard let self,
                  self.requireDirectMessages(action: "p2pEventReceipt") else { return }
            await self.provider.sendReceipt(
                peerYxAccId: self.peerYxAccId,
                lastReceivedMessageId: lastReceivedMessageId
            )
        }
    }

    // MARK: - 账户权限

    /// 所有 P2P 入口必须经过该总闸门，不能只依赖 ChatDetailContainer 的 UI 显隐。
    private func requireDirectMessages(action: String) -> Bool {
        guard !isDirectMessagesAccessRevoked else { return false }
        guard directMessagesGate(action) else {
            if isDirectMessagesPermissionResolved() {
                revokeDirectMessagesAccess()
            }
            return false
        }
        return true
    }

    /// 动态撤权时立即解除 SDK delegate、清空敏感内存态；所有 async 返回点会再经过
    /// `requireDirectMessages`，因此已经发出的请求不能把旧历史或乐观消息写回页面。
    private func revokeDirectMessagesAccess() {
        guard !isDirectMessagesAccessRevoked else { return }
        isDirectMessagesAccessRevoked = true
        provider.unsubscribe()
        pendingEvents.removeAll()
        clientToServerId.removeAll()
        analyticsSentMessageIds.removeAll()
        analyticsFirstReplyIncomingIds.removeAll()
        pendingBottomBadge = 0
        isLoadingMore = false
        isEndReached = true
        state = .empty
    }

    private static func defaultDirectMessagesGate(action: String) -> Bool {
        #if HILY_TESTS
        true
        #else
        SelfPermissionBridge.shared.gate(.directMessages, action: action)
        #endif
    }

    private static func defaultDirectMessagesPermissionResolved() -> Bool {
        #if HILY_TESTS
        true
        #else
        SelfPermissionBridge.shared.isLoaded
        #endif
    }

    private static var defaultDirectMessagesPublisher: AnyPublisher<Bool, Never>? {
        #if HILY_TESTS
        nil
        #else
        SelfPermissionBridge.shared.$canDirectMessages.eraseToAnyPublisher()
        #endif
    }

    private static var defaultDirectMessagesLoadedPublisher: AnyPublisher<Bool, Never>? {
        #if HILY_TESTS
        nil
        #else
        SelfPermissionBridge.shared.$isLoaded.eraseToAnyPublisher()
        #endif
    }

    private static func sameDirectMessagesPermission(
        _ lhs: (Bool, Bool),
        _ rhs: (Bool, Bool)
    ) -> Bool {
        lhs.0 == rhs.0 && lhs.1 == rhs.1
    }

    // MARK: - 内部：乐观 UI 更新工具

    private func appendOptimistic(_ msg: ChatMessage) {
        switch state {
        case .empty:
            state = .loaded([msg])
        case .loaded(let current):
            state = .loaded(current + [msg])
        case .loading, .error:
            // 冷启动或错误态点发送不合法（UI 层应 disable 输入）
            return
        }
    }

    private func updateStatus(clientMsgId: String, transform: (ChatMessageStatus) -> ChatMessageStatus) {
        guard case .loaded(let current) = state else { return }
        var changed = false
        let updated = current.map { m -> ChatMessage in
            guard m.clientMsgId == clientMsgId else { return m }
            let newStatus = transform(m.status)
            guard newStatus != m.status else { return m }
            changed = true
            var copy = m; copy.status = newStatus; return copy
        }
        if changed { state = .loaded(updated) }
    }

    /// 发送完成回调统一入口（成功 / 拉黑 / 可重试失败）
    private func finalizeSending(clientMsgId: String, messageId: String?, error: SendError?) {
        guard case .loaded(let current) = state else { return }
        var changed = false
        var sentMessageForPropagate: ChatMessage?
        let updated = current.map { m -> ChatMessage in
            guard m.clientMsgId == clientMsgId else { return m }
            changed = true
            var copy = m
            if let err = error {
                switch err {
                case .refused(let reason): copy.status = .refused(reason: reason)
                case .retryable(let code): copy.status = .failed(errorCode: code)
                }
            } else if let messageId, !messageId.isEmpty {
                var reconstructed = ChatMessage(
                    id: messageId,
                    clientMsgId: clientMsgId,
                    from: copy.from, to: copy.to,
                    content: copy.content,
                    status: .sent,
                    timestamp: copy.timestamp,
                    isOutgoing: copy.isOutgoing
                )
                // H-3：ChatMessage 新增 var 字段（chatBubble / privateId / msgType）需同步保留（Major-5：新加字段必须在所有构造点同步）
                reconstructed.chatBubble = m.chatBubble
                reconstructed.privateId = m.privateId
                reconstructed.msgType = m.msgType
                copy = reconstructed
                clientToServerId[clientMsgId] = messageId
                sentMessageForPropagate = copy
            }
            return copy
        }
        if changed { state = .loaded(updated) }
        // H-2 spec §4.2 red team #6：发送成功后主动 emit MessageSessionStore.update
        // 让会话列表 lastMessage 立即联动，不依赖 SDK didUpdate 回调保底
        if let sent = sentMessageForPropagate {
            propagateSentToSessionStore(sent)
            trackOutgoingMessage(sent, previousMessage: current.last)
            // Batch 6.2a：主播回复成功 → 触发 settleReplyPoints（累加 currentProgress + hasHistoryReply=true）
            // 对齐 H5 chat/index.vue:1080-1096 sendText/sendPicture 成功后 chatStore.replyPointSettle
            #if !HILY_TESTS
            triggerSettleReplyPoints(for: sent)
            #endif
        }
    }

    /// Batch 6.2a：主播消息发送成功 → 结算回复积分。
    /// - .text/.image/.video/.audio → 参与结算（ReplyPointsStore 内部用 `state.lastUserMsgInfo.msgType` 传给后端）
    /// - .privateImage/.privateVideo/.systemGift/.missedCall/.systemTip/.system/.chatTip → 短路（对齐 H5 isGift/系统消息不结算）
    ///
    /// **P1-1 修**：msgType 参数**改为不传** —— H5 `message.js:1108` 传的是**用户上一条消息**的 pay/free 属性，
    /// 不是主播这次回复的媒介类型。ReplyPointsStore.onSendAnchorMsg 内部现从 lastUserMsgInfo.msgType 派生。
    private func triggerSettleReplyPoints(for sent: ChatMessage) {
        switch sent.content {
        case .text, .image, .video, .audio: break
        default: return   // 私密 / 礼物 / 系统消息不参与结算
        }
        Task { @MainActor in
            await ReplyPointsStore.shared.onSendAnchorMsg(peer: self.peerYxAccId)
        }
    }

    /// 发送成功后将 lastMessage / timestamp 推给 MessageSessionStore（新对话尚未在 store 中则跳过，靠 SDK didAdd 兜底）
    ///
    /// **HilyTests 屏蔽**：test target 里 `MessageSessionStore.shared` +
    /// `ChatMessageContent.previewText` 不可见（前者依赖 NIMSessionAdapter；
    /// 后者依赖 L10n）。走条件编译在 test 下变 no-op，主 target 逻辑不变。
    private func propagateSentToSessionStore(_ msg: ChatMessage) {
        #if !HILY_TESTS
        guard let existing = MessageSessionStore.shared.session(byPeerId: peerYxAccId) else { return }
        let updated = MessageSession(
            id: existing.id,
            peerNickname: existing.peerNickname,
            peerAvatarURL: existing.peerAvatarURL,
            lastMessage: msg.content.previewText,
            lastMessageTimestamp: msg.timestamp,
            unreadCount: existing.unreadCount,
            isTop: existing.isTop,
            ext: existing.ext
        )
        MessageSessionStore.shared.handleEvent(.update(updated))
        #endif
    }

    private func trackOutgoingMessage(_ message: ChatMessage, previousMessage: ChatMessage?) {
        #if !HILY_TESTS
        guard analyticsSentMessageIds.insert(message.id).inserted else { return }
        let base: [String: Any] = [
            "msg_id": message.id,
            "user_xy_id": peerYxAccId,
            "sendType": "host",
            "content_type": analyticsContentType(for: message.content)
        ]
        AnalyticsTracker.track("im_user_send_msg", properties: base)

        if previousMessage == nil || message.timestamp - (previousMessage?.timestamp ?? message.timestamp) >= 12 * 60 * 60 * 1_000 {
            AnalyticsTracker.track("im_anchor_initiate", properties: base)
        }

        guard let previousMessage, !previousMessage.isOutgoing else { return }
        let responseSeconds = max(0, (message.timestamp - previousMessage.timestamp) / 1_000)
        var replyProperties = base
        replyProperties["reply_to_msg_id"] = previousMessage.id
        replyProperties["response_time_s"] = responseSeconds
        AnalyticsTracker.track("im_anchor_reply", properties: replyProperties)
        AnalyticsTracker.track("h_anchor_msg_reply", properties: replyProperties)
        if analyticsFirstReplyIncomingIds.insert(previousMessage.id).inserted {
            AnalyticsTracker.track("im_anchor_first_reply", properties: replyProperties)
        }
        AnalyticsTracker.track("im_reply_pair", properties: replyProperties)
        #endif
    }

    private func trackPrivateMediaSend(type: String, price: Int?) {
        #if !HILY_TESTS
        let properties: [String: Any] = [
            "type": type,
            "dia": price ?? 0,
            "host_id": SessionStore.shared.user?.userId ?? 0,
            "user_xy_id": peerYxAccId
        ]
        AnalyticsTracker.track("primsg_send_suc", properties: properties)
        AnalyticsTracker.track("h_primsg_send_suc", properties: properties)
        #endif
    }

    /// 私密媒体可绑定礼物价格，必须同时具备礼物与虚拟道具能力。
    private static func canSendPrivateMedia(action: String) -> Bool {
        #if HILY_TESTS
        return true
        #else
        return SelfPermissionBridge.shared.gate(.giftSending, action: action)
            && SelfPermissionBridge.shared.gate(.virtualItems, action: action)
        #endif
    }

    private func analyticsContentType(for content: ChatMessageContent) -> String {
        switch content {
        case .text: return "text"
        case .image: return "image"
        case .video: return "video"
        case .audio: return "audio"
        case .privateImage: return "Private Image"
        case .privateVideo: return "Private Video"
        default: return "system"
        }
    }

    private func removeMessage(clientMsgId: String) {
        guard case .loaded(let current) = state else { return }
        let filtered = current.filter { $0.clientMsgId != clientMsgId }
        state = .loaded(filtered)
    }

    /// 纯逻辑合并（load 时 pendingEvents 走此路径，不触发 side effects）
    private func applyEventLocally(_ event: P2PChatEvent, to msgs: [ChatMessage]) -> [ChatMessage] {
        switch event {
        case .received(let incoming):
            let existing = Set(msgs.map(\.id))
            return msgs + incoming.filter { !existing.contains($0.id) }
        case .sendingCompleted(let clientMsgId, let messageId, let error):
            return msgs.map { m in
                guard m.clientMsgId == clientMsgId else { return m }
                var copy = m
                if let err = error {
                    switch err {
                    case .refused(let r): copy.status = .refused(reason: r)
                    case .retryable(let c): copy.status = .failed(errorCode: c)
                    }
                } else if let messageId, !messageId.isEmpty {
                    var rebuilt = ChatMessage(
                        id: messageId,
                        clientMsgId: clientMsgId,
                        from: m.from,
                        to: m.to,
                        content: m.content,
                        status: .sent,
                        timestamp: m.timestamp,
                        isOutgoing: m.isOutgoing
                    )
                    rebuilt.chatBubble = m.chatBubble
                    rebuilt.privateId = m.privateId
                    rebuilt.msgType = m.msgType
                    copy = rebuilt
                }
                return copy
            }
        case .sendingProgress(let clientMsgId, let progress):
            return msgs.map { m in
                guard m.clientMsgId == clientMsgId, case .uploading = m.status else { return m }
                var copy = m; copy.status = .uploading(progress: progress); return copy
            }
        case .receiptReceived(let ts):
            return msgs.map { m in
                guard m.isOutgoing, case .sent = m.status, m.timestamp <= ts else { return m }
                var copy = m; copy.status = .read; return copy
            }
        }
    }

    // MARK: - 时间戳（可 override 供测试注入）

    var currentTimestampMs: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
}
