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
/// **导航接线**：NavigationStack push 时创建；pop 时销毁。
///
/// **SDK delegate unsubscribe 时机**（S-6:注释与实现对齐,原注释宣称 P2PChatStore.deinit 触发,实际 store 明确不放 deinit,见 P2PChatStore §"delegate 生命周期"）：
/// - **主路径**：ChatDetailView.onDisappear → store.teardown() → NIMChatAdapter.unsubscribe;有 scenePhase != .background 守卫防切后台误触发
/// - **兜底**：NIMChatAdapter 自身 deinit(SwiftUI @StateObject 释放触发)保证 delegate 不残留
/// - **边界**:后台 kill / crash 前若 view 未 dismount → delegate 挂着,下次冷启动重新登录时 activate() 会 add,SDK 层去重(不会 double register)
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
    // P 项目：账户级权限（userType 黑名单，全局硬性）—— UI AND 组合 spec §3.1
    @ObservedObject private var permission = SelfPermissionBridge.shared
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
        Group {
            if permission.canDirectMessages {
                chatDetail
            } else {
                EmptyView()
            }
        }
    }

    private var chatDetail: some View {
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
            canCall: callAuthBridge.canCall && permission.canCall,
            canUsePrivateMedia: canUsePrivateMedia,
            canUseReplyRewards: canUseReplyRewards,
            replyPointsStore: replyPointsStore,
            sheetDetent: sheetDetent,
            onRefreshPrivateMedia: { await loadPrivateAlbum(force: true) }
        )
        // 普通相册不涉及经济能力，可与主聊天加载并行；私密相册、回复奖励均等权限桥完成后再启动。
        .task {
            await loadMyAlbum()
            // 保留原有 AnchorInfoStore.loadIfNeeded（给头像等其他字段兜底）
            await anchorInfoStore.loadIfNeeded()
        }
        .task(id: canUsePrivateMedia) {
            guard canUsePrivateMedia else {
                privateCache = []
                privateLoadState = .idle
                return
            }
            await loadPrivateAlbum()
        }
        .task(id: canUseReplyRewards) {
            guard canUseReplyRewards, chatType == .regular else {
                replyPointsStore.endSession(peer: peerYxAccId)
                return
            }
            await beginReplyPointsSession()
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
        guard canUsePrivateMedia else { return }
        let ids = store.currentPrivateMessageIds
        guard !ids.isEmpty else { return }
        guard let uid = anchorInfoStore.mine?.userId ?? sessionAuthStore.user?.userId else { return }
        do {
            let statuses = try await CheckPrivateInfoHTTPService.shared
                .checkPrivateInfo(userId: String(uid), privateIds: ids)
            guard canUsePrivateMedia else { return }
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
    private func loadPrivateAlbum(force: Bool = false) async {
        guard canUsePrivateMedia else {
            privateCache = []
            privateLoadState = .idle
            return
        }
        guard force || privateLoadState == .idle else { return }
        privateLoadState = .loading
        // userId：优先 mine，兜底 SessionStore.user（登录成功一定有值）
        guard let uid = anchorInfoStore.mine?.userId ?? sessionAuthStore.user?.userId else {
            privateLoadState = .failed
            return
        }
        do {
            let list = try await ChatPrivateMediaHTTPService.shared.fetchList(userId: uid)
            guard canUsePrivateMedia else {
                privateCache = []
                privateLoadState = .idle
                return
            }
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

    /// 私密媒体会创建礼物定价私信，107 需同时关闭礼物与虚拟道具能力。
    private var canUsePrivateMedia: Bool {
        permission.canGiftSending && permission.canVirtualItems
    }

    /// 回复奖励会自动领取钻石，因此仅允许虚拟道具能力开启的账号进入该业务流。
    private var canUseReplyRewards: Bool {
        permission.canVirtualItems
    }

    private func beginReplyPointsSession() async {
        guard canUseReplyRewards, chatType == .regular else { return }
        let tipTexts = ReplyPointsTipTexts(
            guide: L10n.chatGuideTip,
            stimulate: L10n.chatStimulateTip,
            replyPointGuide: L10n.chatReplyFastTip,
            replyRemind: L10n.chatReplyRemindTip
        )
        await replyPointsStore.beginSession(
            peer: peerYxAccId,
            initialLastUserMsg: nil,
            tipTexts: tipTexts
        )

        guard canUseReplyRewards else {
            replyPointsStore.endSession(peer: peerYxAccId)
            return
        }
        await store.waitForInitialLoad()
        guard canUseReplyRewards else {
            replyPointsStore.endSession(peer: peerYxAccId)
            return
        }
        // `store.load()` 与本容器 task 并发。若历史先加载，原 hydrate 会因 session 尚未建立而短路；
        // beginSession 完成后再补一次，保证历史最后一条用户消息能触发积分结算和未回复提醒。
        if case .loaded(let messages) = store.state {
            replyPointsStore.hydrateLastUserMsgFromHistory(
                peer: peerYxAccId,
                msgs: messages,
                tipTexts: tipTexts
            )
        }

        // 首屏结束后再校验历史私密消息 lockStatus，避免与 `store.load()` 并发时取到空 privateIds。
        await checkPrivateMessagesLockStatus()
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
