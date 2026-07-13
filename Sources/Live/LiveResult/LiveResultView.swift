import SwiftUI

/// 直播结果页（对齐 H5 `views/liveEnds/index.vue`）。
///
/// - 顶部自定义 back 图标 → env.liveTermination.perform()（切 MainTab.home + 清 path + LiveStore.reset）
/// - 弱网强制下播（endType=7）时红字提示
/// - Duration `HH:mm:ss`（endTs - beginTs）
/// - 3 张卡：Live Data / Top Gifters（预览 3 + More 全屏 sheet 完整）/ Live to Private Calls
/// - 未关注用户显示 follow 按钮；Message 按钮 iOS 侧占位灰态 disabled + toast（H/I 期接入）
///
/// **展示时机**：LiveRoomView `.fullScreenCover` 挂载。back 时通过 env action 切 tab 到 home，
/// LiveRoomView 随 workPath/homePath 清空自然 dismantle（不需要显式 dismiss）。
struct LiveResultView: View {
    @StateObject private var store: LiveResultStore
    /// 系统 dismiss —— 结果页作为 push 页面时 back 按钮 pop 到宿主 stack 根
    @Environment(\.dismiss) private var dismiss

    /// Top Gifters 全屏列表 sheet
    @State private var showGiftersSheet = false
    /// 提示 toast（未来其它占位提示复用）
    @State private var comingSoonToast: String? = nil

    /// **B spec v7 push 架构**：结果页复用宿主 NavigationStack（Work/Home path），私聊/详情
    /// 直接 push 到外层 stack —— back 天然 pop 回结果页；swipe-back 原生可用；无 fullScreenCover 层。
    /// binding 由 MainTabView 通过 navigationDestination 闭包传入。
    @Binding var hostPath: NavigationPath

    /// sheet 内**独立** NavigationStack path：sheet 内点 Message/Avatar push 到 sheet 自己的 stack，
    /// **不关闭 sheet**（sheet 本身仍是 modal 弹窗，独立层，back 回 gifter 列表）
    @State private var sheetChatPath: NavigationPath = NavigationPath()

    init(range: (begin: Int64, end: Int64)?, endType: Int?, hostPath: Binding<NavigationPath>) {
        _store = StateObject(wrappedValue: LiveResultStore(range: range, endType: endType))
        _hostPath = hostPath
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.Palette.liveBottomDark.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                content
            }

            // toast 显示优先级：store.toast（关注成功等状态反馈）> comingSoonToast（本地占位）
            if let toast = store.toast ?? comingSoonToast {
                toastOverlay(text: toast)
                    .padding(.top, 80)
            }
        }
        .navigationBarBackButtonHidden(true)  // 用自定义 topBar；系统 back 藏起（swipe-back 由 .enableSwipeBack 保留）
        .enableSwipeBack()  // 对齐 .claude/rules/default-swipe-back-on-push-pages.md
        .task {
            // push 子页（详情/私聊）返回时，`.task` 会重跑；已 loaded / emptyRange 就 skip，
            // 避免清屏 loading + 重发接口。对齐 UserProfileView.swift:43-47 pattern。
            if case .loaded = store.state { return }
            if case .emptyRange = store.state { return }
            await store.load()
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Top bar (custom back + spacer)

    private var topBar: some View {
        HStack {
            Button {
                // 结果页作为 push 页面：back 走标准 dismiss（pop 回 Work 根 —— path 已由 LiveResultTransition 重建为单层）
                dismiss()
            } label: {
                // 对齐 H5 liveEnds/index.vue:112 `<img src="live-end-back.webp" class="h-24 w-24">`
                Image("liveResultBack")
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
                    .frame(width: 44, height: 44)  // 44x44 热区（HIG）
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.liveResultBack)
            Spacer()
        }
        .padding(.horizontal, 4)
        .background(Color.black)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            loadingView
        case .emptyRange:
            errorStaticView
        case .error(let msg):
            errorBanner(msg)
        case .loaded(let data):
            loadedContent(data)
        }
    }

    private var loadingView: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .tint(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorStaticView: some View {
        Text(L10n.liveResultLoadFailed)
            .foregroundStyle(.white)
            .font(.system(size: 22))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
    }

    private func errorBanner(_ msg: String) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.white)
                Text(msg).foregroundStyle(.white).font(.footnote)
                Spacer()
                Button(L10n.liveResultRetry) {
                    Task { await store.load() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.2))
                .foregroundStyle(.white)
                .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.top, 20)
            Spacer()
        }
    }

    // MARK: - Loaded

    @ViewBuilder
    private func loadedContent(_ data: LiveStatData) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 顶部标题
                Text(L10n.liveResultTitle)
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
                    .padding(.top, 12)

                // 强制下播原因红字提示（endType=2/4/5/6/7 均显示对应文案；用户主动 endType=1 不显示）
                if let notice = store.forceEndNoticeText {
                    Text(notice)
                        .font(.system(size: 14))
                        .foregroundStyle(.red)
                        .lineSpacing(4)
                }

                // Duration
                Text("\(L10n.liveResultDurationLabel): \(store.durationText)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.4))

                // 卡 1：Live Data 4 列
                liveDataCard(data)

                // 卡 2：Top Gifters
                topGiftersCard(data)

                // 卡 3：Private Calls
                privateCallsCard(data)

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 16)
        }
        .sheet(isPresented: $showGiftersSheet) { giftersFullSheet(data) }
    }

    // MARK: - Card containers

    private func card<Content: View>(title: String,
                                     @ViewBuilder more: () -> AnyView = { AnyView(EmptyView()) },
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                more()
            }
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
            content()
        }
        .padding(12)
        .background(Color(white: 0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Card 1: Live Data

    private func liveDataCard(_ data: LiveStatData) -> some View {
        card(title: L10n.liveResultCardLiveData) {
            HStack(alignment: .top, spacing: 10) {
                statCell(value: data.viewNum, label: L10n.liveResultViewers)
                statCell(value: data.followNum, label: L10n.liveResultFollowers)
                statCell(value: data.giftRanks.count, label: L10n.liveResultGifters)
                statCell(value: data.incomeDiamonds, label: L10n.liveResultDiamonds)
            }
            .padding(.vertical, 10)
        }
    }

    private func statCell(value: Int, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value, format: .number)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
            // 对齐 H5 index.vue:139 `text-white/50 text-14 lh-20`
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }

    // MARK: - Card 2: Top Gifters

    private func topGiftersCard(_ data: LiveStatData) -> some View {
        card(title: L10n.liveResultCardTopGifters) {
            AnyView(
                Button {
                    if !data.giftRanks.isEmpty { showGiftersSheet = true }
                } label: {
                    HStack(spacing: 2) {
                        Text(L10n.liveResultMore)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                        // 对齐 H5 `$language === 'ar' ? 'rotate-180' : ''`：RTL 时箭头镜像指向 leading
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.6))
                            .flipsForRightToLeftLayoutDirection(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(data.giftRanks.isEmpty)
            )
        } content: {
            if data.giftRanksReview.isEmpty {
                emptyRow
            } else {
                HStack(spacing: 10) {
                    ForEach(data.giftRanksReview) { item in
                        TopGifterCell(
                            item: item,
                            isFollowing: store.followInFlight.contains(item.userId),
                            onFollow: { Task { await store.follow(userId: item.userId) } },
                            onMessage: { if let yx = item.yxAccid { hostPath.append(yx) } },
                            onAvatarTap: { hostPath.append(UserProfileRoute.userId(item.userId)) }
                        )
                        .frame(maxWidth: .infinity)
                    }
                    if data.giftRanksReview.count < 3 {
                        ForEach(0..<(3 - data.giftRanksReview.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Card 3: Private Calls

    private func privateCallsCard(_ data: LiveStatData) -> some View {
        card(title: L10n.liveResultCardPrivateCalls) {
            if data.privateCalls.isEmpty {
                emptyRow
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(data.privateCalls.enumerated()), id: \.offset) { _, item in
                        PrivateCallRow(
                            item: item,
                            isFollowing: store.followInFlight.contains(item.userId),
                            onFollow: { Task { await store.follow(userId: item.userId) } },
                            onMessage: { if let yx = item.yxAccid { hostPath.append(yx) } },
                            onAvatarTap: { hostPath.append(UserProfileRoute.userId(item.userId)) }
                        )
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    private var emptyRow: some View {
        // 结算页 gifter 列表 inline 空行——用 .textOnly 保持单行紧凑（icon 会撑高卡片）
        EmptyStateView(style: .textOnly, textFont: .footnote)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }

    // MARK: - Full sheet: all gifters

    private func giftersFullSheet(_ data: LiveStatData) -> some View {
        // 独立 NavigationStack + sheetChatPath —— sheet 内 push Message/Detail 覆盖 sheet 主内容
        // 不切外层 chatPath（避免"看似卡死"），也不关 sheet（对齐用户"直接跳"UX）
        NavigationStack(path: $sheetChatPath) {
            ZStack(alignment: .top) {
                Color(hex: 0x0B0010).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(data.giftRanks.enumerated()), id: \.offset) { _, item in
                            GifterFullRow(
                                item: item,
                                isFollowing: store.followInFlight.contains(item.userId),
                                onFollow: { Task { await store.follow(userId: item.userId) } },
                                onMessage: { if let yx = item.yxAccid { sheetChatPath.append(yx) } },
                                onAvatarTap: { sheetChatPath.append(UserProfileRoute.userId(item.userId)) }
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                    }
                    .padding(.top, 8)
                }

                // sheet 内独立 toast 层（sheet 覆盖外层 toastOverlay，需 sheet 内也挂一份）
                if let toast = store.toast ?? comingSoonToast {
                    toastOverlay(text: toast)
                        .padding(.top, 80)
                }
            }
            .navigationTitle(L10n.liveResultCardTopGifters)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 关闭按钮改 xmark 图标（对齐 iOS sheet 惯例；用户反馈"back"文字易误解为返回上一页）
                ToolbarItem(placement: .cancellationAction) {
                    Button { showGiftersSheet = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel(L10n.liveResultBack)
                }
            }
            .navigationDestination(for: String.self) { peerYxAccId in
                // sheet 内私聊：ChatDetailView 用自定义 navBar，dismiss() pop 回 gifter 列表
                let selfYxAccId = SessionStore.shared.user?.yxAccid ?? ""
                ChatDetailContainer(peerYxAccId: peerYxAccId, selfYxAccId: selfYxAccId)
                    .toolbar(.hidden, for: .navigationBar)
            }
            // 详情↔聊天互跳所有 destination(UserProfileRoute + ChatFromProfileRoute) 统一注册；
            // sheet 场景须显式隐藏 system nav bar（内部 view 自带自定义 navBar，否则叠加）
            .userProfileAndChatDestinations(hidesSystemNavigationBar: true)
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Toast overlay

    private func toastOverlay(text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.black.opacity(0.8), in: Capsule())
            .transition(.opacity)
            .task(id: text) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled { comingSoonToast = nil }
            }
    }
}

// MARK: - Row cells

/// Top gifter 竖版卡片 cell（对齐 H5 topGiftersItem.vue：104x136 卡片 + 头像 + 昵称 + Message 按钮 + 未关注 follow）
private struct TopGifterCell: View {
    let item: GiftRankItem
    let isFollowing: Bool
    let onFollow: () -> Void
    let onMessage: () -> Void
    let onAvatarTap: () -> Void

    var body: some View {
        // 外层 ZStack .topTrailing：Follow 按钮相对**整卡**定位到右上角
        //（对齐 H5 topGiftersItem.vue:20 `absolute top-0 right-0`）
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 6) {
                Button(action: onAvatarTap) {
                    AvatarView(urlString: item.icon, size: 50, kind: .user, persistent: false)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
                .accessibilityLabel(item.nickname ?? "")

                Text(item.nickname ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                // 钻石数已按用户反馈移除（对齐 H5 topGiftersItem.vue —— H5 里也不显示，
                // 送礼金额只在 sheet 内 GifterFullRow 里显示）

                messageButton(enabled: item.yxAccid != nil, onTap: onMessage)
                    .padding(.bottom, 8)
            }
            .frame(width: 104)
            .frame(minHeight: 148)

            // Follow 按钮：卡片右上角（H5 absolute top-0 right-0，不受头像 padding 影响）
            if !item.followed {
                Button(action: onFollow) {
                    // 对齐 H5 topGiftersItem.vue:24 `un-follower.webp`（heart + plus 组合切图 28x20pt）
                    Image("liveResultUnfollow")
                        .renderingMode(.original)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 20)
                        .opacity(isFollowing ? 0.4 : 1.0)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isFollowing)
                .accessibilityLabel(L10n.liveResultFollow)
            }
        }
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 私 call 行 cell（对齐 H5 listItem.vue showCall=true：头像 + 昵称 + 通话时长绿色标签 + follow + Message）
private struct PrivateCallRow: View {
    let item: PrivateCallItem
    let isFollowing: Bool
    let onFollow: () -> Void
    let onMessage: () -> Void
    let onAvatarTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onAvatarTap) {
                AvatarView(urlString: item.icon, size: 50, kind: .user, persistent: false)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.nickname ?? "")

            VStack(alignment: .leading, spacing: 4) {
                Text(item.nickname ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: 0x22D956))
                    Text(LiveResultStore.formatHMS(seconds: item.callDurationSeconds))
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: 0x22D956))
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color(hex: 0x22D956).opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
            }
            Spacer()

            if !item.followed {
                Button(action: onFollow) {
                    // 对齐 H5 listItem.vue:52 `<img src="call-unfollower.webp" class="h-28 w-42">` 42x28pt 横版切图
                    Image("liveResultCallUnfollow")
                        .renderingMode(.original)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 42, height: 28)
                        .opacity(isFollowing ? 0.4 : 1.0)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isFollowing)
                .accessibilityLabel(L10n.liveResultFollow)
            }
            messageButton(enabled: item.yxAccid != nil, onTap: onMessage)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 全屏 sheet 里的 gifter 行（横版：头像 + 昵称 + 送礼数量 + follow + Message）
private struct GifterFullRow: View {
    let item: GiftRankItem
    let isFollowing: Bool
    let onFollow: () -> Void
    let onMessage: () -> Void
    let onAvatarTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onAvatarTap) {
                AvatarView(urlString: item.icon, size: 50, kind: .user, persistent: false)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.nickname ?? "")

            VStack(alignment: .leading, spacing: 4) {
                Text(item.nickname ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Image("liveResultDiamond")
                        .renderingMode(.original)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    Text(item.consumeDiamonds, format: .number)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                }
            }
            Spacer()

            if !item.followed {
                Button(action: onFollow) {
                    // 对齐 H5 listItem.vue:52 `<img src="call-unfollower.webp" class="h-28 w-42">` 42x28pt 横版切图
                    Image("liveResultCallUnfollow")
                        .renderingMode(.original)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 42, height: 28)
                        .opacity(isFollowing ? 0.4 : 1.0)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isFollowing)
                .accessibilityLabel(L10n.liveResultFollow)
            }
            messageButton(enabled: item.yxAccid != nil, onTap: onMessage)
        }
    }
}

/// Message 按钮（对齐 H5 listItem.vue `primary-button h28 w-82 flex-center text-12` + `message.webp`）。
///
/// 主色渐变胶囊：`linear-gradient(90deg, #8515FF 0%, #E40132 98.56%)`（`.primary-button` app.less）
/// icon：`liveResultMessage` 切图 12x12（H5 `h-12 w-12`）
/// 尺寸：H5 `h28 w-82` → 82pt 宽 28pt 高
/// 无 yxAccid 时不显示（对齐 H5 `v-if="item?.yxAccid"`）
@ViewBuilder
private func messageButton(enabled: Bool, onTap: @escaping () -> Void) -> some View {
    if enabled {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Text(L10n.liveResultMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                Image("liveResultMessage")
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 12, height: 12)
            }
            .frame(minWidth: 82, minHeight: 28)
            .background(
                LinearGradient(
                    colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
