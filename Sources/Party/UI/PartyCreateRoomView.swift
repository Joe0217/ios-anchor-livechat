import SwiftUI
import PhotosUI

/// 派对房创房页（E-spec v5，2026-07-10 · 对齐 livechat-h5 用户端设计稿）。
///
/// **蓝本**：`livechat-h5/src/views/party/create.vue`
/// **视觉**：`/Users/joe/Downloads/Party房创房/（主）创建房间-增加直播间模板-已选择.png`
///
/// **架构**：View 只读 `@ObservedObject store: PartyCreateStore`，副作用/网络全收敛进 Store（CLAUDE.md 铁律）。
/// **范围**（v5 拍板 · MVP）：
/// - **保留**：头像圆形占位（+ 相机图标显示但 tap 无操作）/ Room name / Room Tagline / Room language picker / Room Mode picker sheet / Create 按钮
/// - **F 期**：OSS 头像上传 / Background 背景图选择 / 段位不足充值升级引导（本 MVP 仅显示"Lv.X required"toast）
struct PartyCreateRoomView: View {
    @StateObject var store: PartyCreateStore
    @ObservedObject private var permission = SelfPermissionBridge.shared
    var onCreated: (String) -> Void = { _ in }   // 提交成功回调（外部 push PartyRoomView）

    @State private var showModePicker = false
    @State private var showLanguagePicker = false
    @State private var showBackgroundPicker = false
    @State private var photoPickerItem: PhotosPickerItem? = nil
    @FocusState private var textFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    /// 默认构造 —— 提供给 PartyTabRootView 用（Live service 内部构造）
    init(defaultName: String = "", defaultTagline: String = "Let's chat and have fun together.", defaultAvatarUrl: String? = nil, userLevel: Int = 0, taglineLengthLimit: Int = PartyCreateStore.maxTaglineLength, onCreated: @escaping (String) -> Void = { _ in }) {
        _store = StateObject(wrappedValue: PartyCreateStore(
            service: PartyCreateServiceLive(),
            defaultName: defaultName,
            defaultTagline: defaultTagline,
            defaultAvatarUrl: defaultAvatarUrl,
            userLevel: userLevel,
            taglineLengthLimit: taglineLengthLimit
        ))
        self.onCreated = onCreated
    }

    /// 测试/Preview 用注入 store 构造
    init(store: PartyCreateStore, onCreated: @escaping (String) -> Void = { _ in }) {
        _store = StateObject(wrappedValue: store)
        self.onCreated = onCreated
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.Palette.partyListBackground.ignoresSafeArea()
                // 空白区域点击失焦（对齐 H5 用户端体验）
                .contentShape(Rectangle())
                .onTapGesture { textFieldFocused = false }

            ScrollView {
                VStack(spacing: 20) {
                    avatarBlock.padding(.top, 20)
                    sectionName
                    sectionTagline
                    sectionLanguage
                    sectionMode
                    sectionBackground   // v7 对齐安卓 6 字段
                    Color.clear.frame(height: 80)   // 底部 Create 按钮预留空间
                }
                .padding(.horizontal, 20)
                // ScrollView 内空白区也失焦
                .contentShape(Rectangle())
                .onTapGesture { textFieldFocused = false }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)

            createButton.padding(.bottom, 20).padding(.horizontal, 20)
        }
        // maxlength 拦截（对齐 rule list-refresh-preserve-items 精神：View 层 onChange 更可靠）
        .onChange(of: store.roomName) { _ in store.trimNameIfNeeded() }
        .onChange(of: store.roomTagline) { _ in store.trimTaglineIfNeeded() }
        // 相册选图 → 上传
        .onChange(of: photoPickerItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await store.uploadAvatar(rawData: data)
                }
                photoPickerItem = nil
            }
        }
        .navigationTitle(L10n.Party.createNavTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Theme.Palette.partyListBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            await store.loadInitial()
            store.refreshPartyVideoCapability()
        }
        .onChange(of: permission.canPartyVideo) { allowed in
            // 账号被动态降为 107 时，关闭已打开的双房型 picker，避免用户停留在视频 tab。
            if !allowed { showModePicker = false }
            store.refreshPartyVideoCapability()
        }
        .sheet(isPresented: $showModePicker) {
            PartyCreateModePickerSheet(store: store) { showModePicker = false }
                .giftPanelSheetBackground()
                .presentationDetents([.fraction(0.8)])
        }
        .sheet(isPresented: $showLanguagePicker) {
            PartyCreateLanguagePickerSheet(store: store) { showLanguagePicker = false }
                .giftPanelSheetBackground()
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showBackgroundPicker) {
            PartyCreateBackgroundPickerSheet(store: store) { showBackgroundPicker = false }
                .giftPanelSheetBackground()
                .presentationDetents([.fraction(0.8)])
        }
        .onChange(of: store.createdRoomId) { id in
            if let id, !id.isEmpty {
                store.clearCreatedRoomId()
                onCreated(id)
            }
        }
        // submitError toast overlay（对齐安卓失败 toast，让用户看到错误原因）
        .overlay(alignment: .top) {
            if !store.submitError.isEmpty {
                Text(store.submitError)
                    .toastStyle()
                    .transition(Toast.transition)
                    .task(id: store.submitError) {
                        try? await Task.sleep(nanoseconds: Toast.dismissDurationLongNanos)
                        store.clearSubmitError()
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.submitError.isEmpty)
    }

    // MARK: - Avatar block

    private var avatarBlock: some View {
        PhotosPicker(selection: $photoPickerItem, matching: .images) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .strokeBorder(
                        LinearGradient(colors: [Theme.Palette.partyCreateAvatarRing1, Theme.Palette.partyCreateAvatarRing2],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 3
                    )
                    .background(
                        Circle().fill(Theme.Palette.partyCardFill)
                    )
                    .frame(width: 120, height: 120)
                    .overlay(avatarOverlay)

                // 相机小图标（tap 整个头像触发 PhotosPicker，icon 仅装饰）
                Circle()
                    .fill(Theme.Palette.partyCreateAvatarCameraBg)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "camera.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                    )
                    .offset(x: -8, y: -4)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Change avatar")
    }

    @ViewBuilder
    private var avatarOverlay: some View {
        if store.isUploadingAvatar {
            Circle().fill(Color.black.opacity(0.4))
                .overlay(ProgressView().tint(.white))
        } else if let url = store.uploadedAvatarUrl ?? store.defaultAvatarUrl,
                  !url.isEmpty,
                  let u = URL(string: url) {
            // v7 对齐安卓：本地上传优先 → fallback 登录默认头像
            CachedAsyncImage(url: u, persistent: true, cdn: (.avatarLarge, .fill)) {
                Color.clear
            }
            .clipShape(Circle())
            .padding(3)   // 让内容不覆盖 strokeBorder
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: 44))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    // MARK: - Sections

    private var sectionName: some View {
        section(title: L10n.Party.createSectionName) {
            HStack {
                TextField(L10n.Party.createNamePlaceholder, text: $store.roomName)
                    .focused($textFieldFocused)
                    .foregroundColor(Theme.Palette.partyCreateInputText)
                    .tint(Theme.Palette.partyCreateChevron)
                Spacer()
                Text("\(store.roomName.count)/\(PartyCreateStore.maxNameLength)")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Palette.partyCreateInputCounter)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                Capsule().fill(Theme.Palette.partyCreateInputFill)
            )
            .overlay(
                Capsule().stroke(Theme.Palette.partyCreateInputBorder, lineWidth: 0.5)
            )
        }
    }

    private var sectionTagline: some View {
        section(title: L10n.Party.createSectionTagline) {
            HStack {
                TextField(L10n.Party.createTaglinePlaceholder, text: $store.roomTagline)
                    .focused($textFieldFocused)
                    .foregroundColor(Theme.Palette.partyCreateInputText)
                    .tint(Theme.Palette.partyCreateChevron)
                Spacer()
                Text("\(store.roomTagline.count)/\(store.taglineLengthLimit)")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Palette.partyCreateInputCounter)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                Capsule().fill(Theme.Palette.partyCreateInputFill)
            )
            .overlay(
                Capsule().stroke(Theme.Palette.partyCreateInputBorder, lineWidth: 0.5)
            )
        }
    }

    private var sectionLanguage: some View {
        section(title: L10n.Party.createSectionLanguage) {
            Button {
                if !store.languages.isEmpty { showLanguagePicker = true }
            } label: {
                HStack {
                    Text(store.selectedLanguage?.languageName ?? "—")
                        .foregroundColor(Theme.Palette.partyCreateInputText)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.Palette.partyCreateChevron)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    Capsule().fill(Theme.Palette.partyCreateInputFill)
                )
                .overlay(
                    Capsule().stroke(Theme.Palette.partyCreateInputBorder, lineWidth: 0.5)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var sectionBackground: some View {
        section(title: L10n.Party.createSectionBackground) {
            Button {
                showBackgroundPicker = true
            } label: {
                VStack(spacing: 12) {
                    HStack {
                        Text(store.selectedBackground?.bgImgName ?? "—")
                            .foregroundColor(Theme.Palette.partyCreateInputText)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.Palette.partyCreateChevron)
                    }
                    // 已选背景预览大图 + Permanent/duration 标签
                    if let bg = store.selectedBackground {
                        Divider().background(Theme.Palette.partyCardBorder)
                        ZStack(alignment: .bottomTrailing) {
                            backgroundThumbnail(bg, big: true)
                                .frame(maxWidth: .infinity)
                                .frame(height: 140)
                                // CachedAsyncImage 默认 contentMode=.fill —— 缺 .clipped() 图片
                                // 撑大后超出 140h 参与父 VStack 布局；.clipShape 只 clip 视觉不 clip layout。
                                // .clipped() 必须**在** .clipShape **之前**（先硬矩形 clip layout，再圆角 clip 视觉）
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            Text(bg.isPermanent ? L10n.Party.createBgPermanent : "\(bg.duration ?? 0)s")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.black.opacity(0.55)))
                                .padding(8)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Theme.Palette.partyCreateInputFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Theme.Palette.partyCreateInputBorder, lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func backgroundThumbnail(_ bg: PartyBackground, big: Bool) -> some View {
        let urlStr = big ? (bg.bigImgUrl ?? bg.imgUrl) : (bg.imgUrl ?? bg.bigImgUrl)
        if let url = urlStr, !url.isEmpty, let u = URL(string: url) {
            CachedAsyncImage(url: u, persistent: true, cdn: (.avatarLarge, .fill)) {
                Rectangle().fill(Theme.Palette.partyCreateTempFill)
            }
        } else {
            Rectangle().fill(Theme.Palette.partyCreateTempFill)
                .overlay(
                    Image(systemName: "photo").foregroundColor(.white.opacity(0.4))
                )
        }
    }

    private var sectionMode: some View {
        section(title: L10n.Party.createSectionMode) {
            Button {
                showModePicker = true
            } label: {
                VStack(spacing: 12) {
                    HStack {
                        Text(store.mode == PartyCreateStore.modeVoice
                             ? L10n.Party.createModeVoice
                             : L10n.Party.createModeLiveVoice)
                            .foregroundColor(Theme.Palette.partyCreateInputText)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.Palette.partyCreateChevron)
                    }
                    // 已选模板 preview：高度锁 100pt，宽度由 image 内在 aspect ratio 自适应
                    if let temp = store.selectedTemplate {
                        Divider().background(Theme.Palette.partyCardBorder)
                        HStack {
                            Spacer()
                            templateThumbnail(temp)
                                .frame(height: 100)
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Theme.Palette.partyCreateInputFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Theme.Palette.partyCreateInputBorder, lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Bottom Create button

    private var createButton: some View {
        VStack(spacing: 8) {
            // canSubmit=false 时展示缺失字段提示，帮用户定位（disable 按钮本身无反馈）
            if let hint = store.missingFieldHint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Palette.partyGreeting)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            actualCreateButton
        }
    }

    private var actualCreateButton: some View {
        Button {
            Task { await store.submit() }
        } label: {
            HStack {
                Spacer()
                if store.isSubmitting {
                    ProgressView().tint(.white).padding(.trailing, 6)
                }
                Text(L10n.Party.createSubmit)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.vertical, 14)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [Theme.Palette.partyCreateBtnA, Theme.Palette.partyCreateBtnB],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            )
            .opacity(store.canSubmit ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!store.canSubmit)
        .accessibilityLabel(L10n.Party.createSubmit)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.Palette.partyCreateSectionTitle)
            content()
        }
    }

    /// 模板缩略图：优先服务端 imgUrl（coverImage）；否则按 videoSeatCount / seatCount 选切图。
    /// 调用点用 `.frame(height: 100).fixedSize(horizontal: true, vertical: false)` 组合让
    /// 宽度按 image aspect ratio 自适应；CachedAsyncImage 分支必须 `contentMode: .fit` 否则
    /// 加载中 placeholder 无 intrinsic width，`fixedSize(horizontal: true)` 会 collapse 到 0
    @ViewBuilder
    private func templateThumbnail(_ temp: PartyRoomTemplate) -> some View {
        if let url = temp.coverImage, !url.isEmpty, let u = URL(string: url) {
            CachedAsyncImage(url: u, contentMode: .fit, persistent: true, cdn: (.avatarSmall, .fit)) {
                // Placeholder 用固定宽度矩形（100:100 方形）避免 loading 期宽度坍缩
                Rectangle().fill(Theme.Palette.partyCreateTempFill).frame(width: 100)
            }
        } else if let asset = Self.assetNameForTemplate(temp) {
            CDNAssetImage(asset).resizable().scaledToFit()
        } else {
            Image(systemName: "square.grid.2x2")
                .resizable().scaledToFit()
                .foregroundColor(Theme.Palette.partyCreateInputCounter)
        }
    }

    /// 根据 videoSeatCount / seatCount fallback 到切图 asset 名
    /// 逻辑已迁到 [PartyRoomTemplate.fallbackAssetName](../Models/PartyRoomTemplate.swift)；
    /// 本 wrapper 保留旧签名给 View 内多处调用点使用
    static func assetNameForTemplate(_ temp: PartyRoomTemplate) -> String? {
        temp.fallbackAssetName
    }
}

// MARK: - Mode picker sheet

/// H5 蓝本：`create.vue:483-514` 底部 popup + tab + 模板卡片网格 + Confirm 按钮
///
/// v7.14 起 UI 抽到 [PartyRoomTemplatePickerSheet](Components/PartyRoomTemplatePickerSheet.swift)
/// 通用组件，与房间内 Room Mode sheet 复用。本 wrapper 只做 create 侧 store 桥接。
///
/// **数据桥**：voice/live 从 `store.visibleTemplates(for:)` 读；107 Party-only 账号只提供语音 tab，
/// 原始 cache 不直接暴露给 UI。
///
/// **Tab 切换**：`onTabChange` → `store.selectMode` → 触发 Store 自动
/// 补拉 + 切 selectedTemplate 到该 mode 首张（保留原副作用链）
///
/// **Confirm**：本地暂存 Store 已校验的 template + mode，
/// 关 sheet；等 submit createRoom 时才发接口
struct PartyCreateModePickerSheet: View {
    @ObservedObject var store: PartyCreateStore
    var onConfirm: () -> Void

    var body: some View {
        PartyRoomTemplatePickerSheet(
            voiceTemplates: validTemplates(mode: PartyCreateStore.modeVoice),
            liveTemplates: validTemplates(mode: PartyCreateStore.modeLiveVoice),
            availableTypes: availableTemplateTypes,
            isLoading: store.templatesLoading && store.templates.isEmpty,
            errorMessage: store.templatesError.isEmpty ? nil : store.templatesError,
            onRetry: { Task { await store.loadTemplates(for: store.mode) } },
            initialType: initialType,
            initialSelectedTempId: store.selectedTemplate?.id,
            enforceLevelGate: false,          // Create v6 对齐安卓：无等级门槛
            emptyText: L10n.Party.createTemplateEmpty,
            onTabChange: { type in
                // Tab 切换 → store.mode 更新触发 didSet：补拉未 cache 的 mode + 重置 selectedTemplate 到首张
                _ = store.selectMode(type.rawValue)
            },
            onConfirm: { tempId, type in
                // Confirm：从对应 tab 的 filter valid 列表找 tempId → 本地暂存到 store
                let picked = validTemplates(mode: type.rawValue).first { $0.id == tempId }
                guard store.selectMode(type.rawValue),
                      let picked,
                      store.selectTemplate(picked, for: type.rawValue) else { return }
                onConfirm()
            }
        )
    }

    /// PartyRoomModeType.rawValue 1=voice / 2=liveAndVoice；转 store.mode 索引
    private var initialType: PartyRoomModeType {
        store.mode == PartyCreateStore.modeVoice ? .voiceOnly : .liveAndVoice
    }

    private var availableTemplateTypes: [PartyRoomModeType] {
        store.canUseVideoTemplates ? PartyRoomModeType.allCases : [.voiceOnly]
    }

    /// filter valid（对齐 PartyCreateStore.templates computed 的 filter 规则）
    private func validTemplates(mode: Int) -> [PartyRoomTemplate] {
        store.visibleTemplates(for: mode)
    }
}

// MARK: - Language picker sheet

struct PartyCreateLanguagePickerSheet: View {
    @ObservedObject var store: PartyCreateStore
    var onDone: () -> Void

    var body: some View {
        ZStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.languages) { lang in
                        Button {
                            store.selectedLanguage = lang
                            onDone()
                        } label: {
                            HStack {
                                Text(lang.languageName)
                                    .foregroundColor(.white)
                                    .font(.system(size: 15))
                                Spacer()
                                if store.selectedLanguage?.languageCode == lang.languageCode {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(Theme.Palette.partyCreateChevron)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().background(Theme.Palette.partyCardBorder)
                    }
                }
            }
        }
    }
}

// MARK: - Background picker sheet

/// 对齐安卓 `ChoosePartyRoomBackgroundDialog` 网格弹窗。
///
/// 从 v7.13 起 UI 组件抽到 [PartyBackgroundPickerSheet](Components/PartyBackgroundPickerSheet.swift)
/// 通用组件，settings 侧复用同款 —— 避免"一处修 pattern 另一处漏"反复出问题。
///
/// 本 wrapper 只做 create 侧 store 与通用组件的桥接：
/// - 数据源：`store.backgrounds` / `store.backgroundsLoading` / `store.selectedBackground?.id`
/// - Confirm：本地暂存 `store.selectedBackground = picked`，等 submit createRoom 时才发接口
struct PartyCreateBackgroundPickerSheet: View {
    @ObservedObject var store: PartyCreateStore
    var onConfirm: () -> Void

    var body: some View {
        PartyBackgroundPickerSheet(
            backgrounds: store.backgrounds,
            isLoading: store.backgroundsLoading && store.backgrounds.isEmpty,
            initialSelectedId: store.selectedBackground?.id
        ) { picked in
            store.selectedBackground = picked
            onConfirm()
        }
    }
}

// MARK: - Previews

#if DEBUG
struct PartyCreateRoomView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            PartyCreateRoomView(store: mockStore(userLevel: 5))
        }
        .preferredColorScheme(.dark)
    }

    static func mockStore(userLevel: Int) -> PartyCreateStore {
        let fake = PartyCreateServicePreviewFake(
            templates: [
                PartyRoomTemplate(id: 1, modeType: 2, seatCount: 10, videoSeatCount: 1, voiceSeatCount: 10, createRoomLevel: 1),
                PartyRoomTemplate(id: 2, modeType: 2, seatCount: 10, videoSeatCount: 2, voiceSeatCount: 10, createRoomLevel: 3),
                PartyRoomTemplate(id: 3, modeType: 2, seatCount: 10, videoSeatCount: 3, voiceSeatCount: 10, createRoomLevel: 10),
            ],
            languages: [
                PartyLanguage(languageName: "English", languageCode: "en"),
                PartyLanguage(languageName: "العربية", languageCode: "ar"),
                PartyLanguage(languageName: "Türkçe", languageCode: "tr"),
            ]
        )
        let store = PartyCreateStore(service: fake, defaultTagline: "Let's chat and have fun together.", userLevel: userLevel)
        Task { await store.loadInitial() }
        return store
    }
}
#endif
