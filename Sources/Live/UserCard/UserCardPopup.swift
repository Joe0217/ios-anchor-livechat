import SwiftUI
import UIKit

// MARK: - Sheet 挂载 wrapper

/// UserCardPopup 承载值(caller 端 `.userCardSheet(item:)` 用)。
/// 保留 `sheet` 命名对齐 caller 侧已有语义,内部实现用 overlay-based scrim(不用系统 sheet)。
struct UserCardPresentation: Identifiable, Equatable {
    let userId: String
    var id: String { userId }
}

// MARK: - `.userCardSheet(item:)` extension

extension View {
    /// 一行挂载 UserCard modal。
    ///
    /// **实现**: overlay-based custom modal(非系统 `.sheet` / `.fullScreenCover`)。
    /// - **不用系统 sheet**:sheet content 被 UIKit 强制 clip 到 sheet frame,头像无法出 sheet
    /// - **不用 fullScreenCover**:会触发底层 LiveRoomView/PartyRoomView 的 onDisappear → 误下播/退房
    /// - `.overlay` 挂 caller 层:同 view tree,不触发 caller 生命周期变化;头像自由 offset 到全屏任意 y
    ///
    /// - Parameters:
    ///   - item: modal 承载 state,`nil` 关闭
    ///   - onAvatarTap: 头像 tap 回调(nil = 头像不可 tap)
    ///   - onMessageTap: Message 按钮 tap 回调(nil = Message 按钮 disabled)
    func userCardSheet(
        item: Binding<UserCardPresentation?>,
        onAvatarTap: (() -> Void)? = nil,
        onMessageTap: ((_ userId: String, _ yxAccid: String?) -> Void)? = nil
    ) -> some View {
        modifier(UserCardOverlayModifier(
            item: item,
            onAvatarTap: onAvatarTap,
            onMessageTap: onMessageTap
        ))
    }
}

// MARK: - UserCardOverlayModifier(overlay-based modal 承载)

private struct UserCardOverlayModifier: ViewModifier {
    @Binding var item: UserCardPresentation?
    let onAvatarTap: (() -> Void)?
    let onMessageTap: ((String, String?) -> Void)?

    func body(content: Content) -> some View {
        content.overlay {
            ZStack(alignment: .bottom) {
                if let p = item {
                    // Backdrop:半透黑 + tap 关闭 + 淡入淡出
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.25)) { item = nil }
                        }
                        .transition(.opacity)

                    // Card:底部对齐 + slide up 转场;头像 offset -45 悬空到 backdrop 上
                    UserCardPopup(
                        userId: p.userId,
                        onAvatarTap: onAvatarTap,
                        onMessageTap: onMessageTap
                    )
                    .transition(.move(edge: .bottom))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: item?.userId)
        }
    }
}

// MARK: - UserCardPopup(modal card content)

/// 用户名片卡(对齐 H5 `views/liveSetting/components/userCard.vue`)。
///
/// **iOS 主播端定位**: 只覆盖 H5 主播端 `liveSetting` 场景(主播看用户),UI 一律用户态渲染。
/// H5 `isAnchor=true`(主播看别的主播房)分支本项目不实现;`userType` 字段保留供未来里程碑启用。
///
/// **视觉对齐 H5**:
/// - 深紫渐变背景 240° `#17175A → #1D0E4C 35% → #130A2A`
/// - 头像 86pt 悬出卡片顶端 45pt(H5 `.photo-bg { top: -55px }`)—— overlay-based modal 支持真溢出
/// - 头饰道具框:静态图走 `AvatarView.headwearURL`,SVGA 走 `HeadFrameView`(对齐 H5 `<head-frame>` 分流)
/// - 左上 Block pill(未拉黑 vs 已拉黑 视觉区分)
/// - 底部 Follow / Message 双按钮
struct UserCardPopup: View {
    let userId: String
    var onAvatarTap: (() -> Void)? = nil
    var onMessageTap: ((_ userId: String, _ yxAccid: String?) -> Void)? = nil

    @StateObject private var store: UserCardStore

    /// 头像上半悬出卡片顶端的高度(视觉,对齐 H5 `.photo-bg { top: -55px }`)
    private static let avatarOverhang: CGFloat = 45
    /// 头像 block 总高(粉紫渐变环 96 + 头饰 116pt 的最大值)
    private static let avatarBlockHeight: CGFloat = 116

    // 礼物墙横滚 chevron 显隐控制(PreferenceKey 监 offset + contentWidth 派生)
    @State private var giftScrollGeom: GiftScrollGeometry = .zero
    @State private var giftContainerWidth: CGFloat = 0

    init(userId: String,
         service: UserCardServiceProtocol = UserCardServiceReal(),
         onAvatarTap: (() -> Void)? = nil,
         onMessageTap: ((String, String?) -> Void)? = nil) {
        self.userId = userId
        self._store = StateObject(wrappedValue: UserCardStore(userId: userId, service: service))
        self.onAvatarTap = onAvatarTap
        self.onMessageTap = onMessageTap
    }

    var body: some View {
        // Bug 修复(2026-07-15):
        // 原实现把 cardBackgroundLayer 作为 ZStack 兄弟层,LinearGradient 是"fill-proposed"的 view,
        // 在 modal wrapper 的 ZStack 里被提议全屏 → LinearGradient 撑到全屏 → body 变屏幕等高 + backdrop 被吸收 tap 无法关闭。
        //
        // 现改:cardBg 用 `.background()` 修饰符附加到 contentLayer,background 只填充宿主尺寸(content-sized),
        // card 自动缩到内容高度,backdrop 上方露出可 tap 关闭。
        // avatar 的 `.offset(y: -avatarOverhang)` 溢出仍不被 background 覆盖(background 只在 host 内渲染),
        // 头像上半 45pt 显示在 backdrop 层上 —— 视觉悬空效果保留。
        contentLayer
            .frame(maxWidth: .infinity)
            .background(cardBackground)
            // 吸收 card 内 empty-area tap 防止穿透到 backdrop 误关闭
            // (Buttons 因 hit-test 优先仍正常响应;此 modifier 只捕获落在 card frame 内但没被 Button 消费的 tap)
            .contentShape(Rectangle())
            .onTapGesture { /* absorb, no-op */ }
            .preferredColorScheme(.dark)
            // P0-4 每次 modal open 强制 refetch(对齐 H5 `watch isShow immediate`)
            .onAppear { store.refresh() }
            .confirmationDialog(
                L10n.userCardUnblockConfirmTitle,
                isPresented: $store.showingUnblockConfirm,
                titleVisibility: .visible
            ) {
                Button(L10n.userCardUnblockConfirmButton, role: .destructive) {
                    store.confirmUnblock()
                }
                Button(L10n.userCardUnblockConfirmCancel, role: .cancel) {
                    store.cancelUnblockConfirm()
                }
            } message: {
                Text(L10n.userCardUnblockConfirmMessage)
            }
    }

    // MARK: - 卡片背景(顶部圆角 16 + 深紫渐变;向下延伸到屏幕底 safe area)

    private var cardBackground: some View {
        LinearGradient(
            colors: [
                Color(hex: 0x17175A),
                Color(hex: 0x1D0E4C),
                Color(hex: 0x130A2A),
            ],
            startPoint: .topTrailing,
            endPoint: .bottomLeading
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // 让背景向下延伸到屏幕底 safe area(iOS sheet 惯例:card 贴屏底,无留白)
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - 内容层(按 state 分流)

    @ViewBuilder
    private var contentLayer: some View {
        switch store.state {
        case .idle, .loading:
            VStack {
                Spacer(minLength: 80)
                ProgressView().tint(.white)
                Spacer(minLength: 40)
            }
            .frame(height: 300)
        case .loaded(let info):
            profileContent(info)
        case .error:
            errorView
        }
    }

    // MARK: - 主要资料内容

    private func profileContent(_ info: UserCardInfo) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 8) {
                // 头像 block:layout 71pt(116 - 45 overhang) + visual offset -45
                // → 视觉 y=-45..71(top 45pt 悬出卡片顶端 = backdrop 层);下 71pt 压在卡片内
                avatarBlock(info: info)
                    .frame(height: Self.avatarBlockHeight - Self.avatarOverhang, alignment: .top)
                    .offset(y: -Self.avatarOverhang)

                // 昵称
                Text(info.nickname)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                // UID: xxx + 复制按钮(tap 复制 userId 到剪贴板 + 全局 toast)
                uidWithCopyButton(userId: info.userId)

                // meta row:性别 pill / 国旗 / Lv 徽章 / VIP
                metaRow(info: info)

                // medals row(独立,横滚兜底防溢出)
                if !info.medals.isEmpty {
                    medalsRow(medals: info.medals)
                }

                // fans / following row
                statsRow(info: info)

                // liveWelcome(可选)
                if let welcome = info.liveWelcome, !welcome.isEmpty {
                    Text(welcome)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                // 礼物墙
                giftWallCard(info: info)
                    .padding(.top, 4)

                // 底部按钮(Follow + Message)
                bottomButtons(info: info)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 15)
            .padding(.bottom, 34)

            // 左上 Block pill
            blockPill(info: info)
                .padding(.leading, 15)
                .padding(.top, 15)
        }
    }

    // MARK: - 头像 block(粉紫渐变环 + 头饰框 SVGA 分流)

    /// **注意**: 不用 `Button + .disabled(onAvatarTap == nil)` —— SwiftUI 系统给 disabled Button 自动
    /// 加半透视觉(.opacity ~0.5),导致头像整块半透。改用 `.onTapGesture`,onAvatarTap == nil 时
    /// 挂空 closure(no-op),视觉保持完全不透明。
    private func avatarBlock(info: UserCardInfo) -> some View {
        ZStack {
            // 粉紫渐变环 96pt(H5 `.photo-bg`)
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: 0xFF9438),
                            Color(hex: 0xFF0091),
                            Color(hex: 0xFE00DE),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 96, height: 96)

            // 白 mask 内环(padding 2pt 让粉紫外环可见;完全不透明)
            Circle()
                .fill(Color.white)
                .frame(width: 91, height: 91)

            // 头像 + 头饰(SVGA 走 HeadFrameView,静态图走 AvatarView.headwearURL)
            headwearAwareAvatar(info: info)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onAvatarTap?()
        }
    }

    /// P0-5 头饰 SVGA 分流:URL 含 `.svga`(不分大小写)→ HeadFrameView 播动画;否则 AvatarView.headwearURL 静态图
    @ViewBuilder
    private func headwearAwareAvatar(info: UserCardInfo) -> some View {
        if let hw = info.headwearUrl, HeadFrameView.isSVGAURL(hw) {
            ZStack {
                AvatarView(
                    urlString: info.avatarUrl,
                    size: 86,
                    kind: .user,
                    headwearURL: nil
                )
                HeadFrameView(urlString: hw, size: 116)
                    .allowsHitTesting(false)
            }
        } else {
            AvatarView(
                urlString: info.avatarUrl,
                size: 86,
                kind: .user,
                headwearURL: info.headwearUrl,
                headwearRatio: 1.35
            )
        }
    }

    // MARK: - UID 展示 + 复制按钮

    /// UID row:`UID: 1000001861 [icon]` —— tap icon 复制 userId 到剪贴板 + 全局 toast
    private func uidWithCopyButton(userId: String) -> some View {
        HStack(spacing: 4) {
            Text(L10n.userCardUidPrefix + userId)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)

            Button {
                UIPasteboard.general.string = userId
                AppToastCenter.shared.show(L10n.userCardUidCopiedToast)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.userCardUidCopyA11y)
        }
    }

    // MARK: - meta row(性别/国旗/Lv/VIP)

    private func metaRow(info: UserCardInfo) -> some View {
        HStack(spacing: 8) {
            if info.gender != .unknown, let age = info.age {
                HStack(spacing: 2) {
                    Image(systemName: info.gender == .female ? "person.fill" : "person")
                        .font(.system(size: 10))
                    Text("\(age)").font(.system(size: 10))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(
                    Capsule().fill(
                        info.gender == .female
                            ? Color(hex: 0xFF1AA7)
                            : Color(hex: 0x205FFF)
                    )
                )
            }

            if let flag = info.countryEmoji {
                Text(flag).font(.system(size: 16))
            }

            // v24（B1）：大 R 徽章（对齐 H5 userCard.vue 徽章 row；`activeTycoon` 后端字段）
            if info.isActiveTycoon {
                ActiveTycoonBadge(style: .bigRText, size: .small)
            }

            if let lv = info.levelName, !lv.isEmpty {
                UserLevelBadge(level: info.level, size: .small)
            }

            if info.isVip {
                PublicChatVipBadge()
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - medals row(独立,横滚兜底防溢出)

    private func medalsRow(medals: [Medal]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(medals) { medal in
                    if let url = medal.imageUrl, !url.isEmpty {
                        CachedAsyncImage(url: URL(string: url),
                                         contentMode: .fit,
                                         persistent: true) {
                            Color.clear
                        }
                        .frame(height: 16)
                    }
                }
            }
            .padding(.horizontal, 15)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - stats row(fans / following)

    private func statsRow(info: UserCardInfo) -> some View {
        HStack(spacing: 0) {
            Text("\(info.followerCount)")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            Text(L10n.userCardFollowers)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
                .padding(.leading, 6)
                .padding(.trailing, 48)

            Text("\(info.followingCount)")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            Text(L10n.userCardFollowing)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
                .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - 礼物墙(含左右箭头指示)

    private func giftWallCard(info: UserCardInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.userCardGiftWall)
                .font(.system(size: 15))
                .foregroundColor(.white)

            if info.giftWalls.isEmpty {
                Text(L10n.userCardEmptyGifts)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            } else {
                giftWallScrollView(info: info)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: 0x23175E),
                            Color(hex: 0x1E1449),
                        ],
                        startPoint: .trailing,
                        endPoint: .leading
                    )
                )
        )
    }

    /// 礼物墙 ScrollView + 左右箭头(H5 `giftScroll` 逻辑对齐):
    /// - offset==0 → 只右箭头(还能右滚)
    /// - offset==max → 只左箭头(还能左滚)
    /// - 中间态 → 双箭头
    /// - contentWidth <= containerWidth → 无箭头(内容不需要滚动)
    private func giftWallScrollView(info: UserCardInfo) -> some View {
        GeometryReader { containerGeo in
            ZStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(info.giftWalls) { g in
                            giftItem(g)
                        }
                    }
                    .padding(.vertical, 6)
                    .background(
                        GeometryReader { contentGeo in
                            Color.clear.preference(
                                key: GiftScrollGeometryKey.self,
                                value: GiftScrollGeometry(
                                    offset: contentGeo.frame(in: .named("giftScroll")).minX,
                                    contentWidth: contentGeo.size.width
                                )
                            )
                        }
                    )
                }
                .coordinateSpace(name: "giftScroll")
                .onPreferenceChange(GiftScrollGeometryKey.self) { newValue in
                    giftScrollGeom = newValue
                }
                .onAppear {
                    giftContainerWidth = containerGeo.size.width
                }
                .onChange(of: containerGeo.size.width) { newWidth in
                    giftContainerWidth = newWidth
                }

                // 左箭头(已右滚时显示)
                if canScrollLeft {
                    HStack {
                        arrowChevron(.left)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
                // 右箭头(未滚到底显示)
                if canScrollRight {
                    HStack {
                        Spacer()
                        arrowChevron(.right)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 72)   // 40 img + 2 name + 12 count + padding.vertical 12 = ~72
    }

    /// 是否可左滚(已从左向右滚出,offset < 0)
    private var canScrollLeft: Bool {
        // 项目太少直接不显示箭头
        guard giftScrollGeom.contentWidth > giftContainerWidth + 1 else { return false }
        return giftScrollGeom.offset < -0.5
    }

    /// 是否可右滚(未滚到内容右尽头)
    private var canScrollRight: Bool {
        guard giftScrollGeom.contentWidth > giftContainerWidth + 1 else { return false }
        // offset 是内容 minX 相对容器 minX 的差;初始 0(内容与容器 minX 对齐)
        // -offset = 内容已经向左滚出的距离
        // 还能右滚的距离 = contentWidth - containerWidth - (-offset) = contentWidth - containerWidth + offset
        return (giftScrollGeom.contentWidth - giftContainerWidth + giftScrollGeom.offset) > 0.5
    }

    private enum ArrowDirection { case left, right }

    private func arrowChevron(_ direction: ArrowDirection) -> some View {
        Image(systemName: direction == .left ? "chevron.left" : "chevron.right")
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.black.opacity(0.4)))
    }

    private func giftItem(_ g: GiftWallItem) -> some View {
        VStack(spacing: 2) {
            if let url = g.iconUrl, !url.isEmpty {
                CachedAsyncImage(url: URL(string: url),
                                 contentMode: .fit,
                                 persistent: true,
                                 cdn: (size: .gift, mode: .fit)) {
                    Color.white.opacity(0.05)
                }
                .frame(width: 40, height: 40)
            } else {
                Color.clear.frame(width: 40, height: 40)
            }
            if let name = g.name, !name.isEmpty {
                Text(name)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 54)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text("X \(g.count)")
                .font(.system(size: 12))
                .foregroundColor(.white)
                .frame(width: 54)
                .lineLimit(1)
        }
    }

    // MARK: - 底部按钮(Follow + Message)

    private func bottomButtons(info: UserCardInfo) -> some View {
        HStack(spacing: 12) {
            // Follow / Followed
            Button {
                store.toggleFollow()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: info.isFollowed ? "checkmark" : "plus")
                        .font(.system(size: 14, weight: .bold))
                    Text(info.isFollowed ? L10n.userCardUnfollow : L10n.userCardFollow)
                        .font(.system(size: 18, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(followBackground(followed: info.isFollowed))
            }
            .buttonStyle(.plain)
            .disabled(store.pendingFollow)
            .opacity(store.pendingFollow ? 0.6 : 1.0)

            // Message(仅 onMessageTap != nil 时显示)
            if onMessageTap != nil {
                Button {
                    onMessageTap?(info.userId, info.yxAccid)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "message.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text(L10n.userCardMessage)
                            .font(.system(size: 18, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Capsule().fill(Color(hex: 0x3625AA)))
                }
                .buttonStyle(.plain)
                .disabled(info.isBlocked || info.yxAccid == nil || info.yxAccid?.isEmpty == true)
                .opacity((info.isBlocked || info.yxAccid == nil) ? 0.5 : 1.0)
            }
        }
    }

    @ViewBuilder
    private func followBackground(followed: Bool) -> some View {
        if followed {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                )
        } else {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x8E60E6), Color(hex: 0xD074E9)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
    }

    // MARK: - Block pill(左上角)

    private func blockPill(info: UserCardInfo) -> some View {
        Button {
            store.handleBlockTap()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: info.isBlocked ? "hand.raised.slash.fill" : "hand.raised.fill")
                    .font(.system(size: 12))
                Text(info.isBlocked ? L10n.userCardUnblock : L10n.userCardBlock)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(
                info.isBlocked
                    ? Color.white.opacity(0.55)
                    : Color(hex: 0xFF4340)
            )
            .padding(.leading, 9)
            .padding(.trailing, 13)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    info.isBlocked
                        ? Color.white.opacity(0.1)
                        : Color(hex: 0xFFC0C0, opacity: 0.1)
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.pendingBlock || info.yxAccid == nil || info.yxAccid?.isEmpty == true)
        .opacity((store.pendingBlock || info.yxAccid == nil) ? 0.4 : 1.0)
    }

    // MARK: - Error view

    private var errorView: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 80)
            Text(L10n.userCardErrorRetry)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))
            Button {
                store.retry()
            } label: {
                Text(L10n.liveRoomRetry)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
    }
}

// MARK: - Gift wall scroll geometry(PreferenceKey 传 offset + contentWidth 到父)

private struct GiftScrollGeometry: Equatable {
    var offset: CGFloat = 0
    var contentWidth: CGFloat = 0

    static let zero = GiftScrollGeometry(offset: 0, contentWidth: 0)
}

private struct GiftScrollGeometryKey: PreferenceKey {
    static var defaultValue: GiftScrollGeometry = .zero
    static func reduce(value: inout GiftScrollGeometry, nextValue: () -> GiftScrollGeometry) {
        let n = nextValue()
        // 只在有效数据时更新(避免 GeometryReader 早期 layout 传 0 覆盖真值)
        if n.contentWidth > 0 { value = n }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("modal") {
    Color.gray
        .userCardSheet(
            item: .constant(UserCardPresentation(userId: "1000001877")),
            onMessageTap: { _, _ in }
        )
}
#endif
