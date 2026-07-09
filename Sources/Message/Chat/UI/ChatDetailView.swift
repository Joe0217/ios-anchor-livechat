import SwiftUI
import PhotosUI

/// P2P 私聊页主容器（H-2 spec §4.1，对齐 H5 `chat/index.vue` 结构）。
///
/// **顶层布局**：
/// ```
/// VStack:
///   ├─ 顶部 nav（返回 + 头像 + 昵称，渐变背景）
///   ├─ 消息列表（LazyVStack + ScrollViewReader；上拉触发 loadMore）
///   └─ 输入栏（ChatInputBar）
///   顶层 overlay：VoiceRecordingOverlay + MediaPickerSheet
/// ```
///
/// **性能关键**（用户强调）：
/// - `LazyVStack` 惰性渲染，避免 100+ 消息全渲染
/// - `.id(message.id)` 稳定 identity（对齐 swiftui-camera-preview.md §1 精神）
/// - `.onChange` 精确监听 pendingBottomBadge / state 而非整个 store
struct ChatDetailView: View {

    @StateObject var store: P2PChatStore

    /// 对端头像 URL（由外层 MessageListView 传入，或从 store.conversationProfiles 读）
    let peerNickname: String
    let peerAvatarURL: URL?
    let myAvatarURL: URL?

    /// 主播 profile 里的媒体列表（由外层从 AnchorInfoStore 传入）
    let mediaItems: [AnchorMediaItem]
    let mediaItemsLoading: Bool

    /// Batch 3.7 私密相册列表（GiftMessageService.fetchList 拉，走 privateInfo 接口）
    let privateItems: [AnchorMediaItem]
    let privateItemsLoading: Bool

    /// 对端业务 userId（H-2 通话入口用；nil = ConversationProfile 未拉齐或后端未返；tap 通话按钮时降级 toast）
    let peerUserId: Int?

    /// 半屏 sheet 模式的关闭回调（nil = 走全屏 `dismiss()`；非 nil = wrapper 传入的 `{ isPresented = false }`）。
    /// nav bar 左侧图标据此切换：`chevron.left`（back）/ `xmark`（close）。
    let onClose: (() -> Void)?

    // H-3 spec §1.5.13 / §4.2.2
    /// 会话类型（`.regular` 4 按钮 / `.customer` 仅普通相册），由 Container 从 peerYxAccId 派生
    let chatType: ChatType
    /// 视频通话权限（从 CallAuthBridge.canCall 派生；未 loaded / mine.levelName 未在 achorHideButton 内 → false）
    let canCall: Bool

    // Batch 6.1：回复积分状态（订阅 store 的 sessions[peer] 派生 RewardProgress 显示）
    @ObservedObject var replyPointsStore: ReplyPointsStore

    // MARK: - view state

    @State private var inputText: String = ""
    @State private var inputMode: ChatInputBar.InputMode = .text
    @State private var showMediaSheet: Bool = false
    @State private var showPrivateMediaSheet: Bool = false   // H-3 私密相册 sheet（Batch 4 补 PrivateMediaSheet 实现）
    @State private var voiceState: VoiceRecordingState?
    /// Batch 3.7：图片/视频预览统一走公共 MediaGalleryView（原 FullScreenImagePreview / VideoPlayerFullScreen 已废弃）
    @State private var galleryContext: MediaGalleryContext?
    // Batch 3.8：客服场景走系统相册 PhotosPicker（非主播上传的相册）
    @State private var showSystemPhotoPicker: Bool = false
    @State private var systemPhotoPickerItems: [PhotosPickerItem] = []
    // Batch 6.1.4：奖励记录弹窗 hoist 到 ChatDetailView 层，用 fullScreenCover 屏幕居中,避开消息气泡遮挡
    @State private var showRewardRecords: Bool = false
    @State private var rewardRecords: [MessageBoxRecordItem] = []
    @State private var isLoadingRewardRecords: Bool = false
    // Batch 6.1.4：通话在线状态拦截 toast（对齐 H5 c-callButton.vue:86 "is busy" / "is not online"）
    @State private var callToastShow: Bool = false
    @State private var callToastMessage: String = ""
    // Batch 6.3.3：翻译后文本内存态 map（message.id → 译文）；离开页面清 nil（对齐 H5 spec §1.3 "不持久化"）
    @State private var translatedTexts: [String: String] = [:]
    @StateObject private var voiceRecorder = VoiceRecorder()
    @ObservedObject private var audioPlayer = ChatAudioPlayer.shared
    /// 上拉分页节流（相邻 400ms 内的顶部触发合并）
    @State private var lastLoadMoreAt: Date = .distantPast
    /// 初次挂载 ScrollView 时先 opacity=0 藏起来,scrollTo(BOTTOM) settle 后再 opacity=1 淡入,
    /// 避免用户看到"从顶部滚到底部"的观感(LazyVStack 惰性实例化沿途 row 视觉上像滚动)。
    @State private var didInitialScroll: Bool = false
    /// Batch 6.4：追踪原始 store 最尾一条真实消息的 stableId,用于精确判定"何时该滚底"(替换 count 判据)
    /// tips 混入 / finalizeSending id 替换 / loadMore prepend 都不会改变 lastRealBottomId → 不误触发
    @State private var lastRealBottomId: String? = nil
    /// Batch 6.4：loadMore 前捕获当前视觉最顶消息 stableId,加载完 scrollTo(anchor:.top) 保持视口位置
    @State private var savedTopMessageId: String? = nil
    /// 用户当前是否在消息列表底部 —— bottom sentinel `.onAppear/.onDisappear` 驱动。
    /// - true = 底部锚点在渲染窗口内(收新消息自动滚底 + 清 pendingBottomBadge)
    /// - false = 用户在上翻历史(收新消息只累加 badge,不打断浏览)
    /// 初值 true 对齐"进入页面即滚到底部"语义。
    @State private var isAtBottom: Bool = true
    /// 键盘管理（H-2 键盘管理精细化）：
    /// - `.scrollDismissesKeyboard(.interactively)` — 用户拖列表时键盘自然滑走（iM 惯例）
    /// - 键盘弹出 → 自动滚到底部（`onChange(of: isInputFocused)` 处理）
    /// - mode → voice 时 ChatInputBar 内部收键盘（观察 mode 变化）
    /// - send 后 `inputText = ""` 但 focus 保持（不主动 dismiss，便于连发）
    @FocusState private var isInputFocused: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - body

    var body: some View {
        ZStack(alignment: .bottom) {
            ChatPalette.pageBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                navBar
                // Batch 6.1：顶部宝箱进度条（对齐 H5 `chat/index.vue:1011` `<RewardProgress v-if="!chatType">`）
                // 仅 regular 会话 + isOpenPaidMessage 才显示；view 内部自判
                if chatType == .regular {
                    RewardProgressView(
                        peer: store.peerYxAccId,
                        store: replyPointsStore,
                        onTapRecords: handleTapRewardRecords
                    )
                }
                messageListContainer
                // Batch 3.8：系统会话（notification）只读——隐藏输入栏 + 底部操作栏
                if chatType != .system {
                    ChatInputBar(
                        text: $inputText,
                        mode: $inputMode,
                        onSend: handleSendText,
                        onVoicePressStart: handleVoiceStart,
                        onVoicePressEnd: handleVoiceEnd,
                        textFieldFocus: $isInputFocused
                    )
                    BottomActionBar(
                        chatType: chatType,
                        canCall: canCall,
                        inputMode: inputMode,
                        onToggleVoice: { inputMode = (inputMode == .voice) ? .text : .voice },
                        onTapCall: handleTapCall,
                        // customer 时 photo 按钮走系统 PhotosPicker（客服场景发本地图片）；regular 走主播上传的相册
                        onOpenRegularAlbum: handleOpenAlbum,
                        onOpenPrivateAlbum: { showPrivateMediaSheet = true }
                    )
                }
            }

            VoiceRecordingOverlay(state: voiceState)
        }
        .task {
            await store.load()
            // 60s 到点自动 stop 时触发发送
            voiceRecorder.onAutoStopReachMax = { [weak store] url, dur in
                Task { @MainActor in
                    await store?.sendAudio(localFilePath: url.path, dur: dur, previewURL: url)
                }
            }
        }
        .onDisappear {
            // H-2 spec §4.8：真正离开页面才解 delegate；切后台不解（回前台仍要收增量消息）
            // 对齐 swiftui-fullscreencover-hoist.md §2 精神：onDisappear 需 scenePhase 守卫防 background 误触发
            guard scenePhase != .background else { return }
            store.teardown()
        }
        .sheet(isPresented: $showMediaSheet) {
            MediaPickerSheet(
                items: mediaItems,
                isLoading: mediaItemsLoading,
                onSend: handleSendMedia,
                onDismiss: { showMediaSheet = false }
            )
            .sheetTopInset()
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.hidden)
        }
        // Batch 3.7 私密相册 sheet：GiftMessageService.fetchList 拉真数据；send 走 P2PChatStore.sendPrivateImage/Video
        .sheet(isPresented: $showPrivateMediaSheet) {
            MediaPickerSheet(
                items: privateItems,
                isLoading: privateItemsLoading,
                showLockIcon: true,
                onSend: handleSendPrivateMedia,
                onDismiss: { showPrivateMediaSheet = false }
            )
            .sheetTopInset()
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.hidden)
        }
        // Batch 3.7：统一公共 MediaGalleryView 全屏预览（含图 + 视频；对齐朋友圈 CircleView 用法）
        .fullScreenCover(item: $galleryContext) { ctx in
            MediaGalleryView(urls: ctx.urls, startIndex: ctx.startIndex)
        }
        // Batch 6.3.1：钻石领取弹窗 —— 订阅 pendingClaimDiamond auto-claim 触发
        .overlay {
            if let n = replyPointsStore.pendingClaimDiamond, n > 0 {
                DiaReceivePopup(
                    diamondCount: n,
                    onGet: { replyPointsStore.pendingClaimDiamond = nil }
                )
                .transition(.opacity)
                .zIndex(200)   // 高于 rewards records (zIndex 100)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: replyPointsStore.pendingClaimDiamond)
        // Batch 6.1.4：奖励记录弹窗 —— overlay 顶层覆盖(iOS 16.0 不支持 fullScreenCover 透明背景;overlay 满屏黑遮罩自然全覆盖)
        .overlay {
            if showRewardRecords {
                RewardRecordsPopup(
                    records: rewardRecords,
                    freeMessagePoints: AppConfigStore.shared.freeMsgPoints ?? 0,
                    paidMessagePoints: AppConfigStore.shared.payMsgPoints ?? 0,
                    isLoading: isLoadingRewardRecords,
                    onClose: { showRewardRecords = false }
                )
                .transition(.opacity)
                .zIndex(100)   // 高层级避免被消息气泡遮挡
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showRewardRecords)
        // Batch 6.1.4：通话在线状态拦截 toast（对齐 H5 c-callButton.vue "is busy" / "is not online" 提示）
        .overlay(alignment: .top) {
            if callToastShow {
                Text(callToastMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.85), in: Capsule())
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: callToastMessage) {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        withAnimation { callToastShow = false }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: callToastShow)
        // Batch 3.8：客服会话 photo 按钮 → 系统 iOS 相册选图 → 上传 CDN → send
        .photosPicker(isPresented: $showSystemPhotoPicker,
                      selection: $systemPhotoPickerItems,
                      matching: .images)
        .onChange(of: systemPhotoPickerItems) { items in
            handleCustomerPhotoSelected(items)
        }
        .navigationBarBackButtonHidden(true)
        // H-3 spec §4.12 / §F-57~59：恢复系统左边缘右滑返回手势（`navigationBarBackButtonHidden(true)` 副作用禁用了它）
        .swipeToPopEnabled()
        // Task 11：声明本 view 属于 GiftEffect .chat 场景；Chat 场景 IM SEND_GIFT 有 svga/mp4 时弹中央大动画（无动画走消息气泡不启 MicroToast）
        .giftEffectScene(.chat, scopeId: store.peerYxAccId)
    }

    // MARK: - Nav

    private var navBar: some View {
        HStack(spacing: 10) {
            Button {
                if let onClose { onClose() } else { dismiss() }
            } label: {
                Image(systemName: onClose != nil ? "xmark" : "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(onClose != nil ? "Close" : "Back")

            // 对方 = 用户（kind: .user）；接入 headwear 字段后可补头像框
            AvatarView(url: peerAvatarURL, size: ChatConstants.navAvatarSize, kind: .user)

            Text(peerNickname)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer()

            // H-3 spec §1.5.5：视频通话按钮从 nav 移到底部 BottomActionBar 第 2 位（对齐 H5 line 1050）
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(ChatPalette.navGradient)
    }

    // H-3 spec §1.5.5：nav callButton private var 已移除；handleTapCall 由 BottomActionBar tap 触发

    // MARK: - Message list

    private var messageListContainer: some View {
        Group {
            switch store.state {
            case .loading:
                loadingState
            case .empty:
                emptyState
            case .error(let msg):
                errorState(msg)
            case .loaded(let messages):
                // Batch 6.2b：混入 ReplyPointsStore.tips 到消息列表（按 stableSortKey 排序）
                messageList(mergedItems(messages))
            }
        }
        .frame(maxHeight: .infinity)
        // H-3 v4 (2026-07-08)：点击消息列表空白区域收键盘
        // 用 TapGesture（非 DragGesture）—— rule swiftui-root-draggesture-mindist-zero.md：
        // 挂 DragGesture(minimumDistance:0) 会瘫痪下层 slider/drag；TapGesture 安全
        .onTapGesture {
            if isInputFocused { isInputFocused = false }
        }
    }

    private var loadingState: some View {
        ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.4))
            Text("Say hi to start chatting")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.6))
            Text(msg)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Retry") { Task { await store.retry() } }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Batch 6.2b：将 ReplyPointsStore.tips(for: peer) 转为 ChatMessage.chatTip 塞进消息列表，
    /// 按 `stableSortKey = timestamp * 100 + tieBreaker` 混合排序（对齐 H5 chatStore tip 混入 messagesData）
    /// - tieBreaker：真实消息=0；guide=1 / replyPointGuide=2 / replyRemind=3 / stimulate=4
    /// - 让 tip 出现在**同时间戳**真实消息后（同 ts 但 tieBreaker 更大 → 排序靠后）
    private func mergedItems(_ messages: [ChatMessage]) -> [ChatMessage] {
        let tips = replyPointsStore.tips(for: store.peerYxAccId)
        guard !tips.isEmpty else { return messages }

        let tipMessages: [ChatMessage] = tips.map { tip in
            ChatMessage(
                id: "tip-\(tip.id.uuidString)",
                clientMsgId: nil,
                from: "system",
                to: store.peerYxAccId,
                content: .chatTip(kind: tip.kind, text: tip.text, tipTs: tip.timestamp),
                status: .sent,
                timestamp: tip.timestamp,
                isOutgoing: false
            )
        }
        return (messages + tipMessages).sorted { lhs, rhs in
            Self.stableSortKey(lhs) < Self.stableSortKey(rhs)
        }
    }

    /// 消息 + tip 统一排序 key（对齐 ChatTip.stableSortKey 语义）
    private static func stableSortKey(_ m: ChatMessage) -> Int64 {
        if case .chatTip(let kind, _, _) = m.content {
            return m.timestamp * 100 + Int64(kind.tieBreaker)
        }
        return m.timestamp * 100   // 真实消息 tieBreaker=0
    }

    // MARK: - Batch 6.4 滚动位置派生信号（对齐 tranquil-popping-church plan）

    /// 派生"最尾一条真实消息 identity"—— 只从 store.state.loaded 派生,忽略 tips
    /// - nil = 空消息列表 / loading / error
    /// - (stableId, isOutgoing) = 尾部真实消息标识 + 是否我方
    private var bottomAnchorSignal: BottomAnchor? {
        guard case .loaded(let msgs) = store.state, let last = msgs.last else { return nil }
        return BottomAnchor(stableId: last.stableId, isOutgoing: last.isOutgoing)
    }

    /// 当前尾部真实消息 stableId（onAppear 初始化 lastRealBottomId 用）
    private var currentBottomStableId: String? {
        guard case .loaded(let msgs) = store.state else { return nil }
        return msgs.last?.stableId
    }

    /// 当前顶部真实消息 stableId（topSentinel loadMore 前捕获用）
    private var currentTopStableId: String? {
        guard case .loaded(let msgs) = store.state else { return nil }
        return msgs.first?.stableId
    }

    /// Batch 6.4 bottomAnchor 变化处理:
    /// - 我方发消息（isOutgoing=true）→ 无条件滚底
    /// - 对方消息 + 用户在底部（isAtBottom=true）→ 滚底 + 清 badge(store.handleReceived 已累加,滚到底后立即清)
    /// - 对方消息 + 用户浏览历史(isAtBottom=false）→ 不滚,让 badge 展示"N new"
    /// **无 withAnimation**——对齐 H5 直接跳到底部
    ///
    /// 用 isAtBottom 而非 pendingBottomBadge==0 判定"用户在底部":
    /// store 收到消息 badge 立即 +1,view 侧读到时已>0,pendingBottomBadge 无法反映"before-this-message"状态。
    private func handleBottomAnchorChange(_ new: BottomAnchor?, proxy: ScrollViewProxy) {
        guard let new, new.stableId != lastRealBottomId else { return }
        lastRealBottomId = new.stableId
        if new.isOutgoing || isAtBottom {
            proxy.scrollTo("BOTTOM", anchor: .bottom)
            // 我方发/对方消息-且-用户在底部:滚底后 badge 应清(handleReceived 已累加,现视觉已到底)
            if store.pendingBottomBadge > 0 {
                store.markBottomReached()
            }
        }
    }

    /// bottomAnchorSignal 派生结构（Equatable + Hashable 供 .onChange 判定变化）
    private struct BottomAnchor: Equatable, Hashable {
        let stableId: String
        let isOutgoing: Bool
    }

    private func messageList(_ messages: [ChatMessage]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // 顶部上拉触发 sentinel
                    if !store.isEndReached {
                        topSentinel
                    }

                    // Batch 6.4：ForEach id 用 stableId (clientMsgId ?? id) —— 发送成功 SDK 回填 messageId 时 identity 不变,不 dismantle/reinsert 尾行
                    ForEach(Array(messages.enumerated()), id: \.element.stableId) { index, msg in
                        // 时间分隔（相邻消息 ≥5min）
                        if shouldShowTimeSeparator(at: index, in: messages) {
                            ChatTimeSeparator(timestamp: msg.timestamp)
                        }
                        ChatMessageRow(
                            message: msg,
                            myAvatarURL: myAvatarURL,
                            peerAvatarURL: peerAvatarURL,
                            playingAudioClientId: audioPlayer.playingKey,
                            onTapAudio: handleTapAudio,
                            onTapVideo: handleTapVideo,
                            onTapImage: handleTapImage,
                            onResend: handleResend,
                            translatedText: translatedTexts[msg.id],
                            onLongPressTranslate: handleTranslate
                        )
                        .id(msg.stableId)   // scrollTo anchor 与 ForEach id 一致
                    }

                    // 底部锚点用于自动滚 + 感知"用户在底部"状态。
                    // .onAppear = 底部进入渲染窗口(用户滚到底 or 首次 layout 完成) → isAtBottom=true + 清 badge
                    // .onDisappear = 底部离开渲染窗口(用户上翻历史) → isAtBottom=false
                    Color.clear
                        .frame(height: 1)
                        .id("BOTTOM")
                        .onAppear {
                            isAtBottom = true
                            if store.pendingBottomBadge > 0 {
                                store.markBottomReached()
                            }
                        }
                        .onDisappear {
                            isAtBottom = false
                        }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .opacity(didInitialScroll ? 1 : 0)
            // Batch 6.4：精准滚底判据 —— 观察原始 store 最尾一条真实消息 identity 变化,而非 mergedItems.count
            //   - tips 混入不触发（bottomAnchorSignal 从 store.state.loaded 派生,tips 变化 bottomAnchor 不变）
            //   - loadMore prepend 不触发（last 不变）
            //   - finalizeSending id 替换不触发（stableId 稳定）
            .onChange(of: bottomAnchorSignal) { newSignal in
                handleBottomAnchorChange(newSignal, proxy: proxy)
            }
            // 键盘弹出时跳到底部让最新消息紧贴输入框(对齐 iM 惯例)。
            // 键盘动画 ~250ms;多帧兜底(0/100/300ms)覆盖动画全程,无 withAnimation(避免与键盘曲线叠加"跳动")。
            .onChange(of: isInputFocused) { focused in
                guard focused else { return }
                let lastId = messages.last?.stableId
                let scrollBottom: () -> Void = {
                    if let id = lastId {
                        proxy.scrollTo(id, anchor: .bottom)
                    } else {
                        proxy.scrollTo("BOTTOM", anchor: .bottom)
                    }
                }
                scrollBottom()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    scrollBottom()
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    scrollBottom()
                }
            }
            // Batch 6.4：loadMore 完成后 scrollTo(savedTopMessageId, anchor: .top) 保持视口位置
            .onChange(of: store.isLoadingMore) { isLoading in
                if !isLoading, let anchor = savedTopMessageId {
                    proxy.scrollTo(anchor, anchor: .top)
                    savedTopMessageId = nil
                }
            }
            .onAppear {
                // 初始化 lastRealBottomId 避免首次真实消息到达时误判为"新消息追加"
                lastRealBottomId = currentBottomStableId
                // iOS 16 SwiftUI 已知问题:LazyVStack 首帧 layout 未完成时 scrollTo 会失效或只 partial scroll,
                // 单次调用不稳定;多次尝试(0 + 16ms + 50ms + 120ms)兜底,最后一次后再淡入 ScrollView。
                // scrollTo 目标优先用 messages.last?.stableId(LazyVStack 更容易定位到具体 row),兜底 "BOTTOM"。
                let lastId = messages.last?.stableId
                let scrollToBottom: () -> Void = {
                    if let id = lastId {
                        proxy.scrollTo(id, anchor: .bottom)
                    } else {
                        proxy.scrollTo("BOTTOM", anchor: .bottom)
                    }
                }
                scrollToBottom()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 16_000_000)   // 1 帧
                    scrollToBottom()
                    try? await Task.sleep(nanoseconds: 34_000_000)   // +2 帧
                    scrollToBottom()
                    try? await Task.sleep(nanoseconds: 70_000_000)   // +4 帧,布局稳定后最后一次
                    scrollToBottom()
                    withAnimation(.easeIn(duration: 0.15)) { didInitialScroll = true }
                }
            }
            // pendingBadge tap 要调 proxy.scrollTo，overlay 必须留在 ScrollViewReader 内
            .overlay(alignment: .bottom) {
                if store.pendingBottomBadge > 0 {
                    pendingBadge(proxy: proxy)
                }
            }
        }
    }

    private var topSentinel: some View {
        Group {
            if store.isLoadingMore {
                ProgressView().tint(.white.opacity(0.5))
                    .frame(height: 30)
            } else {
                Color.clear.frame(height: 1)
                    .onAppear {
                        // 节流：相邻 400ms 内合并（H-2 spec §4.6）
                        let now = Date()
                        guard now.timeIntervalSince(lastLoadMoreAt) >= 0.4 else { return }
                        lastLoadMoreAt = now
                        // Batch 6.4：捕获当前视觉最顶消息 stableId,loadMore 完成后用它 scrollTo(anchor:.top) 保位
                        savedTopMessageId = currentTopStableId
                        Task { await store.loadMore() }
                    }
            }
        }
    }

    /// Batch 6.4：tap badge 主动跳底部 + 清 badge count（原来只清 count 不滚,用户预期 tap 后看到最新消息）
    private func pendingBadge(proxy: ScrollViewProxy) -> some View {
        Button {
            store.markBottomReached()
            proxy.scrollTo("BOTTOM", anchor: .bottom)
            lastRealBottomId = currentBottomStableId   // 同步基线,避免下条消息到达时被判定"新消息"重复滚
        } label: {
            Text("\(store.pendingBottomBadge) new")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(ChatPalette.primaryGradient, in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }

    private func shouldShowTimeSeparator(at index: Int, in messages: [ChatMessage]) -> Bool {
        guard index > 0 else { return true }
        return messages[index].timestamp - messages[index - 1].timestamp >= ChatConstants.timeSeparatorThresholdMs
    }

    // MARK: - Handlers

    private func handleSendText() {
        let text = inputText
        inputText = ""
        Task { await store.sendText(text) }
    }

    /// 相册按钮统一入口——按 chatType 分流：
    /// - `.regular`：主播上传的相册 sheet（MediaPickerSheet 走 AnchorInfoStore/picList）
    /// - `.customer`：系统 iOS 相册（PhotosPicker）—— 客服场景发本地图
    private func handleOpenAlbum() {
        switch chatType {
        case .customer: showSystemPhotoPicker = true
        case .regular:  showMediaSheet = true
        case .system:   break   // 系统会话入口已隐藏，兜底不响应
        }
    }

    /// Batch 3.8：客服会话选完系统相册的图 → 上传 CDN → send
    private func handleCustomerPhotoSelected(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let captured = items
        Task {
            for pi in captured {
                guard let data = try? await pi.loadTransferable(type: Data.self) else { continue }
                do {
                    let urlString = try await ImageUploader.shared.upload(rawData: data, preset: .moment)
                    guard let url = URL(string: urlString) else { continue }
                    let media = AnchorMediaItem(
                        id: UUID().uuidString,
                        mediaUrl: url,
                        coverUrl: nil,
                        kind: .image,
                        dur: nil
                    )
                    await store.sendImage(item: media)
                } catch {
                    // 上传失败：不阻塞后续；NIMChatAdapter 层已有详细日志
                    continue
                }
            }
            await MainActor.run { systemPhotoPickerItems = [] }
        }
    }

    private func handleSendMedia(_ item: AnchorMediaItem) {
        showMediaSheet = false
        Task {
            switch item.kind {
            case .image: await store.sendImage(item: item)
            case .video: await store.sendVideo(item: item)
            }
        }
    }

    /// 私密图/视频发送（Batch 3.7）
    /// - AnchorMediaItem.id 即 privateId（`AnchorMediaItem.fromPrivateMedia` 已保留 PrivateMedia.id）
    /// - 对端 userId 从 `peerUserId` 传入；缺失时无法签发，只 dismiss
    private func handleSendPrivateMedia(_ item: AnchorMediaItem) {
        showPrivateMediaSheet = false
        guard let uid = peerUserId else { return }
        let peerUidStr = String(uid)
        let selection = PrivateMediaSelection(
            privateId: item.id,
            iconType: item.kind == .video ? 2 : 1,
            url: item.mediaUrl,
            coverUrl: item.coverUrl,
            dur: item.dur
        )
        Task {
            if selection.isVideo {
                await store.sendPrivateVideo(peerUserId: peerUidStr, media: selection)
            } else {
                await store.sendPrivateImage(peerUserId: peerUidStr, media: selection)
            }
        }
    }

    private func handleVoiceStart() {
        voiceRecorder.start()
        voiceState = .recording(seconds: 0)
        // 订阅 recorder seconds 更新到 overlay
        Task { @MainActor in
            for await sec in voiceRecorder.$currentSeconds.values {
                guard voiceRecorder.isRecording else { break }
                voiceState = (voiceState == .willCancel(seconds: sec))
                    ? .willCancel(seconds: sec)
                    : .recording(seconds: sec)
            }
        }
    }

    private func handleVoiceEnd(cancelled: Bool) {
        defer { voiceState = nil }
        if cancelled {
            voiceRecorder.cancel()
            return
        }
        guard let (url, dur) = voiceRecorder.stop() else {
            // <1s 或异常，无需发送
            return
        }
        Task { await store.sendAudio(localFilePath: url.path, dur: dur, previewURL: url) }
    }

    private func handleTapAudio(_ msg: ChatMessage) {
        guard case .audio(let url, _) = msg.content else { return }
        let key = msg.clientMsgId ?? msg.id
        audioPlayer.toggle(url: url, key: key)
    }

    private func handleTapVideo(_ msg: ChatMessage) {
        guard case .video(let url, _, _) = msg.content else { return }
        galleryContext = MediaGalleryContext(urls: [url.absoluteString], startIndex: 0)
    }

    private func handleTapImage(_ msg: ChatMessage) {
        guard case .image(let url, _) = msg.content else { return }
        galleryContext = MediaGalleryContext(urls: [url.absoluteString], startIndex: 0)
    }

    private func handleResend(_ msg: ChatMessage) {
        guard let clientId = msg.clientMsgId else { return }
        Task { await store.resend(clientMsgId: clientId) }
    }

    /// Batch 6.3.3：长按对方文字消息 → 走 TranslateService 拉译文,存 map（离开页面清）
    /// - 目标语言：iOS 设备当前语言（`Locale.current.language.languageCode?.identifier`）；主播端全球通用兜底 en
    /// - config: 从 AppConfigStore 派生 microsoft key/area（TranslateConfigBridge 已建）
    /// - 失败静默；重复 tap 已翻译消息 → 无操作（map hit 短路）
    private func handleTranslate(_ msg: ChatMessage) {
        guard case .text(let text) = msg.content else { return }
        guard translatedTexts[msg.id] == nil else { return }   // 已翻译 → 短路
        guard let key = AppConfigStore.shared.microsoftTranslatorKey,
              let area = AppConfigStore.shared.microsoftTranslatorArea,
              !key.isEmpty, !area.isEmpty else {
            callToastMessage = "Translation config missing"
            callToastShow = true
            return
        }
        let targetLang = Locale.current.language.languageCode?.identifier ?? "en"
        Task {
            do {
                let translated = try await MicrosoftTranslateService.shared.translate(
                    text: text, targetLang: targetLang, key: key, area: area
                )
                translatedTexts[msg.id] = translated
            } catch {
                callToastMessage = "Translation failed"
                callToastShow = true
            }
        }
    }

    /// 拨打视频通话（对齐 H5 `c-callButton.vue:43-89` videoCall()）
    /// **在线状态拦截**（Batch 6.1.4）：
    /// - `onlineGroupStatus == .calling(10000)` 或 `.background(10003)` 等忙碌 → toast "is busy"
    /// - `AnchorOnlineStatus.isOnlineForCall(status) == false` → toast "is not online"
    /// - 其余（在线 / 匹配态 / 通话结束）→ 走 CallStore.callOut
    private func handleTapCall() {
        guard let uid = peerUserId else { return }
        // 若正在通话中直接忽略（避免重复呼出）
        guard CallStore.shared.state == .idle else { return }

        let status = MessageSessionStore.shared.profile(for: store.peerYxAccId)?.onlineGroupStatus
        if !AnchorOnlineStatus.isOnlineForCall(status) {
            // 区分 busy vs offline（H5 c-callButton.vue:85-87）
            let busyStatuses: Set<Int> = [
                AnchorOnlineStatus.calling,        // 10000
                AnchorOnlineStatus.background,     // 10003
                AnchorOnlineStatus.doNotDisturbOpen // 10004
            ]
            if let s = status, busyStatuses.contains(s) {
                showCallToast("\(peerNickname) is busy.")
            } else {
                showCallToast("\(peerNickname) is not online.")
            }
            return
        }
        Task { await CallStore.shared.callOut(remoteUserId: String(uid)) }
    }

    /// Batch 6.1.4：拉取奖励记录 + 打开弹窗（hoist 到 ChatDetailView 层，避免 overlay 被消息气泡遮挡）
    private func handleTapRewardRecords() {
        showRewardRecords = true
        Task {
            isLoadingRewardRecords = true
            defer { isLoadingRewardRecords = false }
            do {
                rewardRecords = try await ReplyPointsHTTPService.shared
                    .fetchMessageBoxRecords(userYxAccid: store.peerYxAccId)
            } catch {
                rewardRecords = []
            }
        }
    }

    /// 通话/在线状态拦截 toast（Batch 6.1.4；简易实现，2s 自消失；未来若需要多 toast 叠加走 helper 层）
    private func showCallToast(_ text: String) {
        // 借用 MediaGalleryContext state 展示原生 alert 更简单——但业务允许直接输出到 log 兜底
        // TODO Batch 6.2 补统一 toast overlay（对齐 MessageListView.showTransientError 模式）
        // 当前先用系统 alert 兜底（用户能看到提示）
        callToastMessage = text
        callToastShow = true
    }
}

