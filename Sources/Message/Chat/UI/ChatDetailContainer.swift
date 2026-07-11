import SwiftUI

/// 私聊页真轨接线容器（H-2 spec §6.2 step 2）。
///
/// **职责**：
/// - 组装 `P2PChatStore + NIMChatAdapter`（真 SDK 桥）
/// - 从 `MessageSessionStore.shared.conversationProfiles[peer]` 取对端头像/昵称
/// - **相册数据源**（Batch 3.6 修正 2026-07-08）：`EditProfileService.fetchUserInfoWithReview`
///   拿真接口的 `picList` 分流（`AnchorInfo.pictures/videos` 是 iOS 侧臆想字段接口不返，见
///   [EditProfileStore.swift](../../../Profile/EditProfile/EditProfileStore.swift):118）
/// - 从 `SessionStore.shared.user.yxAccid` 取自己 yxAccId
///
/// **导航接线**：NavigationStack push 时创建；pop 时销毁（P2PChatStore.deinit 触发 unsubscribe）。
struct ChatDetailContainer: View {

    let peerYxAccId: String
    /// 半屏模式的关闭回调（`.sheet` 显示时由 wrapper 传入 `{ isPresented = false }`）；
    /// 全屏 push 场景传 nil，走标准 `dismiss()`
    let onClose: (() -> Void)?
    /// 若本聊天页是从某个用户的详情页 push 出来的，携带该 userId。
    /// 消息 row tap 头像时若匹配则 pop 回详情页，避免详情↔聊天栈无限嵌套（详见 ChatFromProfileRoute）。
    let originProfileUserId: String?
    /// 半屏 sheet 承载时的 detent selection binding（wrapper 传入）—— 键盘弹起时 ChatDetailView 主动切 `.large`
    /// 避免键盘遮挡触发系统被迫 resize 与键盘上升不同步导致卡顿。nil = push 模式或无需主动切换。
    let sheetDetent: Binding<PresentationDetent>?

    @StateObject private var store: P2PChatStore
    @ObservedObject private var sessionStore: MessageSessionStore = .shared
    @ObservedObject private var anchorInfoStore: AnchorInfoStore = .shared
    // H-3 spec §1.5.13：客服/系统会话动态判定 chatType；订阅 customerServiceIdStore 变化
    @ObservedObject private var customerIdStore: CustomerServiceIdStore = .shared
    // H-3 spec §2.6：CallAuthBridge 派生 canCall（订阅 AppConfigStore + AnchorInfoStore.$mine）
    @StateObject private var callAuthBridge = CallAuthBridge()
    // Batch 6.1：订阅回复积分 store,view 层显示 RewardProgress + tips
    @ObservedObject private var replyPointsStore: ReplyPointsStore = .shared

    // Batch 3.6：本地相册缓存 —— 从 EditProfileService.picList 分流
    @State private var mediaCache: [AnchorMediaItem] = []
    @State private var mediaLoadState: MediaLoadState = .idle
    // Batch 3.7：私密相册缓存 —— 从 GiftMessageService.fetchList 拉
    @State private var privateCache: [AnchorMediaItem] = []
    @State private var privateLoadState: MediaLoadState = .idle
    @ObservedObject private var sessionAuthStore: SessionStore = .shared

    private enum MediaLoadState { case idle, loading, loaded, failed }

    init(peerYxAccId: String, selfYxAccId: String, onClose: (() -> Void)? = nil, originProfileUserId: String? = nil, sheetDetent: Binding<PresentationDetent>? = nil) {
        self.peerYxAccId = peerYxAccId
        self.onClose = onClose
        self.originProfileUserId = originProfileUserId
        self.sheetDetent = sheetDetent
        let adapter = NIMChatAdapter(peerYxAccId: peerYxAccId, selfYxAccId: selfYxAccId)
        // Batch 6.2a：预组装 4 tip L10n 文案传给 P2PChatStore → 让 store 内部结算路径能 append stimulate tip
        let tipTexts = ReplyPointsTipTexts(
            guide: L10n.chatGuideTip,
            stimulate: L10n.chatStimulateTip,
            replyPointGuide: L10n.chatReplyFastTip,
            replyRemind: L10n.chatReplyRemindTip
        )
        _store = StateObject(wrappedValue: P2PChatStore(
            peerYxAccId: peerYxAccId,
            selfYxAccId: selfYxAccId,
            provider: adapter,
            sendPrivateInfoService: SendPrivateInfoHTTPService.shared,
            replyPointsTipTexts: tipTexts
        ))
    }

    var body: some View {
        ChatDetailView(
            store: store,
            peerNickname: peerNickname,
            peerAvatarURL: peerAvatarURL,
            myAvatarURL: myAvatarURL,
            mediaItems: mediaCache,
            mediaItemsLoading: mediaLoadState == .loading || mediaLoadState == .idle,
            privateItems: privateCache,
            privateItemsLoading: privateLoadState == .loading || privateLoadState == .idle,
            peerUserId: peerUserId,
            originProfileUserId: originProfileUserId,
            onClose: onClose,
            chatType: chatType,
            canCall: callAuthBridge.canCall,
            replyPointsStore: replyPointsStore,
            sheetDetent: sheetDetent
        )
        // Batch 3.6+3.7：进入私聊页并行拉普通相册（picList）+ 私密相册（privateInfo）
        // Batch 6.1：regular 会话时触发 ReplyPointsStore.beginSession（拉 messageBoxList + auto-claim）
        .task {
            async let myAlbum: Void = loadMyAlbum()
            async let privateAlbum: Void = loadPrivateAlbum()
            _ = await (myAlbum, privateAlbum)
            // 保留原有 AnchorInfoStore.loadIfNeeded（给头像等其他字段兜底）
            await anchorInfoStore.loadIfNeeded()

            // regular 会话才触发回复积分 beginSession；system / customer 会话不走
            if chatType == .regular {
                await replyPointsStore.beginSession(
                    peer: peerYxAccId,
                    initialLastUserMsg: nil,   // TODO Batch 6.2:从 P2PChatStore.messagesData 找 last incoming
                    tipTexts: ReplyPointsTipTexts(
                        guide: L10n.chatGuideTip,
                        stimulate: L10n.chatStimulateTip,
                        replyPointGuide: L10n.chatReplyFastTip,
                        replyRemind: L10n.chatReplyRemindTip
                    )
                )

                // 校验历史私密消息 lockStatus(对齐 H5 chat/index.vue checkPrivateInfo)
                // P2PChatStore.load 已完成拉历史(与 .task 顺序:store 是 @StateObject,其 .task 内 load 与本 .task 并发,
                // 但 checkPrivateMessagesLockStatus 内会等 store.state == .loaded 再取 privateIds,若尚未 load 完就返 [] 短路)。
                await checkPrivateMessagesLockStatus()
            }
        }
        // 离开页面清 session 内 sticky 字段（对齐 spec §Q7 "pop 即清"）
        .onDisappear {
            replyPointsStore.endSession(peer: peerYxAccId)
        }
    }

    // MARK: - checkPrivateInfo 校验私密消息锁定态

    /// 收集当前 store 里所有 private 消息的 privateId → 打网校验 lockStatus → 回写。
    /// 对齐 H5 chat/index.vue checkPrivateInfo():180-206。
    /// 空 privateIds / mine.userId 缺失 / 接口失败 → 静默返(不影响主流程,lockStatus 保持 .unknown 兜底态)。
    private func checkPrivateMessagesLockStatus() async {
        let ids = store.currentPrivateMessageIds
        guard !ids.isEmpty else { return }
        guard let uid = anchorInfoStore.mine?.userId ?? sessionAuthStore.user?.userId else { return }
        do {
            let statuses = try await CheckPrivateInfoHTTPService.shared
                .checkPrivateInfo(userId: String(uid), privateIds: ids)
            store.applyPrivateLockStatuses(statuses)
        } catch {
            // 静默失败:lockStatus 保持 .unknown,UI 无锁 icon 兜底
        }
    }

    // MARK: - 相册加载（Batch 3.6）

    private func loadMyAlbum() async {
        guard mediaLoadState == .idle else { return }
        mediaLoadState = .loading
        do {
            let resp = try await EditProfileService.shared.fetchUserInfoWithReview()
            mediaCache = AnchorMediaItem.fromPicList(resp.picList)
            mediaLoadState = .loaded
        } catch {
            mediaCache = []
            mediaLoadState = .failed
        }
    }

    /// Batch 3.7：拉私密相册（对齐 H5 chat/index.vue:159 `apiGetPrivateInfo({ userId: mineInfo.userId })`）
    private func loadPrivateAlbum() async {
        guard privateLoadState == .idle else { return }
        privateLoadState = .loading
        // userId：优先 mine，兜底 SessionStore.user（登录成功一定有值）
        guard let uid = anchorInfoStore.mine?.userId ?? sessionAuthStore.user?.userId else {
            privateLoadState = .failed
            return
        }
        do {
            let list = try await GiftMessageService.shared.fetchList(userId: uid)
            privateCache = list.compactMap(AnchorMediaItem.fromPrivateMedia)
            privateLoadState = .loaded
        } catch {
            privateCache = []
            privateLoadState = .failed
        }
    }

    // MARK: - H-3 chatType 派生（spec §1.5.13 / §2.7 / §4.2.2）

    /// 从 peerYxAccId 判定会话类型（Batch 3.8 拆 3 态）：
    /// - `.system`：peerYxAccId == 系统通知 P2P（`AppConfig.notificationYxAccId`）— 无输入栏
    /// - `.customer`：peerYxAccId == 客服 P2P（`CustomerServiceIdStore.customerYxAccId`）— 相册走系统 PhotosPicker
    /// - `.regular`：其余（正常主播↔用户会话）
    private var chatType: ChatType {
        if peerYxAccId == AppConfig.notificationYxAccId { return .system }
        if let cid = customerIdStore.customerYxAccId, !cid.isEmpty, peerYxAccId == cid {
            return .customer
        }
        return .regular
    }

    // MARK: - 派生数据

    /// 系统/客服会话走 i18n title（不显示云信 id）
    private var peerNickname: String {
        switch chatType {
        case .system:   return L10n.messageSystemInboxNotification
        case .customer: return L10n.messageSystemInboxAdmin
        case .regular:  return sessionStore.profile(for: peerYxAccId)?.nickname ?? peerYxAccId
        }
    }

    private var peerAvatarURL: URL? {
        sessionStore.profile(for: peerYxAccId)?.icon.flatMap { URL(string: $0) }
    }

    private var peerUserId: Int? {
        sessionStore.profile(for: peerYxAccId)?.userId
    }

    /// 我的头像 —— 走 AnchorInfoStore.iconURL 完整回退链（info → mine → SessionStore.user）
    /// 避免 mine 未拉齐时头像空白（Batch 3.7 修）
    private var myAvatarURL: URL? {
        anchorInfoStore.iconURL
    }
}
