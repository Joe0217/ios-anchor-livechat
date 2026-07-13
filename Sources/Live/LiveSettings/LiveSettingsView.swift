import SwiftUI
import PhotosUI

/// 开播设置页（B-spec-开播设置页 v3）—— 视觉/文案对齐 H5 `views/liveSetting/index.vue` 5 张 CCard。
///
/// **v3 修订**：追 H5 index.vue:230-252 证实相机 `openLocalCameraAndeMic('live')` 在 `handleStartLive`
/// 内、tap Start Live **之后**才启动；本页无相机预览、无内嵌美颜。
/// **v4 修订**：文案/结构对齐 H5 5 张 CCard（Live Bio / Live Cover / Live Call Free 5 Min Gift Setup /
/// Live Wishlist / Beauty Settings），去掉全屏 loading 遮罩，靠底部 Start Live 按钮内 loading 反馈。
///
/// 生产级：3 张卡片（Private Call / Wishlist / Beauty）当前是灰态占位，跳转按钮 disabled +
/// "Coming Soon"；依赖礼物系统（H）/图床（I）等基建就绪后接入。
struct LiveSettingsView: View {
    @StateObject private var store = LiveSettingsStore()
    /// push 到 LiveRoomView 的参数持有；本页不显示美颜 UI。
    @StateObject private var beautyParams = BeautyParameters()
    @State private var goLive = false
    /// 无直播权限 / 开播接口报错时，store 通过 `shouldDismiss` 信号触发 pop 返回
    @Environment(\.dismiss) private var dismiss

    // v5: Cover 上传
    @State private var pickerItem: PhotosPickerItem?

    // v5: 私 call 礼物选择
    @State private var showGiftPicker = false

    private var counterText: String {
        String(format: L10n.liveSettingsCounterFormat, store.title.utf16.count)
    }

    /// 开播按钮可点条件：editing 态；loading/starting/error 全 disable
    private var canTapStart: Bool {
        if case .editing = store.state { return true }
        return false
    }

    /// starting 期间 TextField / 灰态卡片按钮统一 disable
    private var isBusy: Bool { store.state == .starting }

    var body: some View {
        ZStack {
            Theme.Palette.screenBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    if case let .error(msg) = store.state {
                        errorBanner(msg)
                    }
                    bioCard
                    coverCard
                    privateCallCard
                    wishlistCard
                    beautyCard
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)

            // stage 3：toast 覆盖层（对齐 H5 showToast）—— checkCanLive 4 项失败时短暂显示
            if let toast = store.toastMessage {
                VStack {
                    Text(toast).toastStyle()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: store.toastMessage)
                .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { startBar }
        .navigationTitle(L10n.liveSettingsNavTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isBusy)
        .navigationDestination(isPresented: $goLive) {
            if let info = store.roomInfo {
                LiveRoomView(
                    roomInfo: info,
                    title: store.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? L10n.livePrepareDefaultTitle : store.title,
                    beauty: beautyParams
                )
            }
        }
        .task { await store.load() }
        .onAppear {
            // Bug fix：二次开播按钮转圈——LiveSettings 是 push 而非 dismantle 到 LiveRoomView，
            // 从 LiveRoomView 下播 pop 回来时 store 仍 .starting + roomInfo != nil + lock 锁定,
            // tap Start Live 命中 `guard state == .editing` 静默 return → 按钮持续 loading。
            // 检测"已开播过标志"（roomInfo != nil）→ reset 允许再次开播。
            if store.roomInfo != nil {
                store.resetForReuse()
                goLive = false
            }
            // 用户诉求 2026-07-08：进入开播设置页 = 准备开播，offline 时自动上线（免除用户先手动切在线）
            if !OnlineStatusStore.shared.userSetOnline {
                OnlineStatusStore.shared.setUserSetOnline(true)
            }
            // 用户诉求 2026-07-09：进直播 = 独占摄像头，若匹配中先静默关匹配
            // 否则 MatchCameraSession 与直播 CameraManager 抢摄像头 → 直播结束后残留 running
            if MatchStore.shared.state == .matching {
                Task { await MatchStore.shared.closeMatch(silent: true) }
            }
        }
        .onChange(of: store.roomInfo?.id) { newId in
            if newId != nil { goLive = true }
        }
        .onChange(of: store.shouldDismiss) { should in
            // 无直播权限 / getMyLiveRoomV2 / beginLiveRoom 报错时，store 展示 toast 后触发 pop
            if should { dismiss() }
        }
        .onChange(of: pickerItem) { newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    await store.uploadCover(data: data)
                }
                pickerItem = nil  // 清空选择态，下次可再选同一张
            }
        }
        .sheet(isPresented: $showGiftPicker) {
            // H-4 迁移：私 call 门槛 gift picker → CommonGiftPanel（tabs=[.popular], footer=.confirm, minPrice=..., stepper=.hidden）
            CommonGiftPanel(config: .callGate(
                minPrice: store.privateCallGiftMinPrice,
                initialSelection: store.selectedGift,
                onConfirm: { store.setSelectedGift($0) }
            ))
            .sheetTopInset()
            .presentationDetents([.fraction(0.5), .fraction(0.8)])
            .presentationDragIndicator(.visible)
        }
        // 心愿承诺规范弹窗（对齐 H5 wishlist-rule-modal.vue）—— 首次开播含 wishlist+promise 时弹
        // 用 ZStack overlay 而非 sheet：H5 是 dialog 视觉（居中 + dim 背景），非 iOS bottom sheet
        .overlay {
            if store.showWishRuleModal {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea()
                        .onTapGesture { store.onWishRuleClose() }
                    WishRuleModal(
                        onAgree: { await store.onWishRuleAgree() },
                        onClose: { store.onWishRuleClose() }
                    )
                }
                .transition(.opacity)
                .zIndex(1000)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: store.showWishRuleModal)
        .preferredColorScheme(.dark)
    }

    // MARK: - Cards

    private var bioCard: some View {
        cardBlock(title: L10n.liveSettingsBioTitle, intro: L10n.liveSettingsBioIntro, required: true) {
            VStack(alignment: .leading, spacing: 6) {
                TextField(
                    "",
                    text: $store.title,
                    prompt: Text(L10n.liveSettingsBioPlaceholder).foregroundColor(.white.opacity(0.4)),
                    axis: .vertical
                )
                .lineLimit(2...4)
                .foregroundStyle(.white)
                .disabled(isBusy)
                .padding(10)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Spacer()
                    Text(counterText).font(.caption2).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    private var coverCard: some View {
        cardBlock(title: L10n.liveSettingsCoverTitle) {
            HStack(spacing: 12) {
                PhotosPicker(
                    selection: $pickerItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    ZStack {
                        if let url = store.coverUrl, let u = URL(string: url) {
                            CachedAsyncImage(url: u,
                                             contentMode: .fill,
                                             persistent: true,
                                             cdn: (.custom(width: 300), .fit)) {
                                Color.white.opacity(0.06)
                            }
                            .frame(width: 88, height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.white.opacity(0.06))
                                .frame(width: 88, height: 88)
                                .overlay(Image(systemName: "photo").foregroundStyle(.white.opacity(0.35)))
                        }
                        // 上传中遮罩
                        if store.isUploadingCover {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.black.opacity(0.55))
                                .frame(width: 88, height: 88)
                                .overlay(ProgressView().tint(.white))
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isBusy || store.isUploadingCover)

                // stage 3：仅在上传中显示"Uploading..."，非上传态不显示 hint（对齐 H5 无提示语）
                if store.isUploadingCover {
                    Text(L10n.liveSettingsCoverUploading)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
            }
        }
    }

    private var privateCallCard: some View {
        cardBlock(title: L10n.liveSettingsPrivateCallTitle,
                  intro: L10n.liveSettingsPrivateCallIntro) {
            HStack(alignment: .top, spacing: 10) {
                // 二选一：已选礼物 → 只显示 tile（tap 重选，✕ 删除）；未选 → 只显示 + 添加
                if let gift = store.selectedGift {
                    giftTile(gift)
                } else {
                    addGiftTile
                }
                Spacer()
            }
        }
    }

    /// 已选礼物 tile —— 对齐 H5 `views/liveSetting/components/gifts.vue`：
    /// 深色底 60x60 + 图 50x50 + 右上"−"删除 + 底名字（<=10pt）+ 底 💎价格（<=9pt）
    private func giftTile(_ gift: GiftListData) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.6)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                CachedAsyncImage(url: URL(string: gift.giftSmallImg.isEmpty ? gift.giftImg : gift.giftSmallImg),
                                 contentMode: .fit,
                                 persistent: true,
                                 cdn: (.gift, .fit)) {
                    Color.clear
                }
                .frame(width: 50, height: 50)
                .padding(5)
                // 右上"−"删除
                Button {
                    store.setSelectedGift(nil)
                } label: {
                    ZStack {
                        Circle().fill(.white)
                        Rectangle().fill(.black).frame(width: 8, height: 1.5)
                    }
                    .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .padding(.top, 2).padding(.trailing, 2)
            }
            Text(gift.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .frame(maxWidth: 66)
            HStack(spacing: 3) {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow)
                Text("\(gift.giftPrice)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .contentShape(Rectangle())
        // stage 3：tap tile 重开 GiftPicker（保留 ✕ 删除按钮语义）——SwiftUI Button 手势优先于父 tapGesture，
        // 里层"−"按钮点击不会冒泡到本 tapGesture，两者互不干扰
        .onTapGesture {
            guard !isBusy else { return }
            showGiftPicker = true
        }
    }

    /// 添加/更改礼物按钮 —— 60x60 深色底 + "+" 图标（对齐 H5 add tile）
    private var addGiftTile: some View {
        Button {
            showGiftPicker = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.6))
                    .frame(width: 60, height: 60)
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.pink)
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    @ObservedObject private var wishShared = WishSettingSharedStore.shared

    private var wishlistCard: some View {
        cardBlock(title: L10n.liveSettingsWishlistTitle,
                  intro: L10n.liveSettingsWishlistIntro) {
            NavigationLink(value: WorkRoute.wishSetting) {
                VStack(alignment: .leading, spacing: 8) {
                    if !wishShared.wishlist.isEmpty {
                        // 已配置预览：横向 tile row（对齐 H5 wishlist read-only 预览 index.vue:478-487）
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(wishShared.wishlist) { g in
                                    wishlistPreviewTile(g)
                                }
                            }
                        }
                    }
                    // stage 3：L10n 文案本身已含 ">>>" 箭头字符，删掉 chevron.right icon 避免重复
                    Text(L10n.liveSettingsGoToSettings)
                        .font(.footnote.bold())
                        .foregroundStyle(.pink)
                        .padding(.vertical, 4)
                }
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
    }

    /// LiveSettings 主页只读预览 tile（不含 ± / ✕，仅展示图 + 数量徽章 + 名 + 价）
    private func wishlistPreviewTile(_ g: WishGift) -> some View {
        VStack(spacing: 3) {
            ZStack(alignment: .bottomTrailing) {
                Color.black.opacity(0.6)
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                CachedAsyncImage(url: URL(string: g.giftSmallImg),
                                 contentMode: .fit,
                                 persistent: true,
                                 cdn: (.gift, .fit)) {
                    Color.clear
                }
                .frame(width: 42, height: 42).padding(4)
                if g.giftNum > 1 {
                    Text("x\(g.giftNum)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.black.opacity(0.7), in: Capsule())
                        .padding(2)
                }
            }
            Text(g.name).font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.7)).lineLimit(1).frame(maxWidth: 54)
        }
    }

    private var beautyCard: some View {
        cardBlock(title: L10n.liveSettingsBeautyTitle) {
            // K 里程碑：激活跳转到独立美颜设置页（spec §0.4 Q6）
            // stage 3：L10n 文案已含 ">>>"，删 chevron.right icon 与 wishlist 卡视觉一致
            NavigationLink(value: WorkRoute.beautySettings) {
                Text(L10n.liveSettingsGoToSettings)
                    .font(.footnote)
                    .foregroundStyle(Color.pink)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
    }

    // MARK: - Building blocks

    /// H5 CCard 对应封装：title + optional intro（副标题）+ optional 必填星号 + 子内容。
    private func cardBlock<Content: View>(
        title: String,
        intro: String? = nil,
        required: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if required {
                    Text("*").font(.subheadline).foregroundStyle(.pink)
                }
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Spacer()
            }
            if let intro {
                Text(intro)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            content().padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.cardFill, in: RoundedRectangle(cornerRadius: 12))
    }

    /// "Go to Settings >>>" 按钮 —— 当前三个卡片（私 call / Wishlist / Beauty）后续里程碑再开放，
    /// 本次统一灰态 disabled + "Coming Soon" 后缀。
    private func goToSettingsButton() -> some View {
        HStack(spacing: 6) {
            Text(L10n.liveSettingsGoToSettings)
                .font(.footnote)
                .foregroundStyle(Color.pink.opacity(0.55))
            Text("· \(L10n.liveSettingsComingSoon)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // 无 onTapGesture：灰态不响应
    }

    // MARK: - Bottom Start bar

    private var startBar: some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.08))
            Button {
                Task { await store.startTapped() }
            } label: {
                HStack(spacing: 8) {
                    if isBusy { ProgressView().tint(.white) }
                    Text(isBusy ? L10n.livePrepareStarting : L10n.livePrepareStart)
                        .font(.headline).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(canTapStart ? Color.pink : Color.pink.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!canTapStart)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Theme.Palette.screenBackground)
    }

    // MARK: - Error banner

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(msg).font(.footnote).foregroundStyle(.white).lineLimit(3)
            Spacer()
        }
        .padding(12)
        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
    }
}

#if DEBUG
#Preview("editing") {
    NavigationStack { LiveSettingsView() }
        .preferredColorScheme(.dark)
}
#endif
