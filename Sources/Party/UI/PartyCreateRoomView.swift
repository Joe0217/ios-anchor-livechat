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
    var onCreated: (String) -> Void = { _ in }   // 提交成功回调（外部 push PartyRoomView）

    @State private var showModePicker = false
    @State private var showLanguagePicker = false
    @State private var showBackgroundPicker = false
    @State private var photoPickerItem: PhotosPickerItem? = nil
    @FocusState private var textFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    /// 默认构造 —— 提供给 PartyTabRootView 用（Live service 内部构造）
    init(defaultName: String = "", defaultTagline: String = "Let's chat and have fun together.", defaultAvatarUrl: String? = nil, userLevel: Int = 0, onCreated: @escaping (String) -> Void = { _ in }) {
        _store = StateObject(wrappedValue: PartyCreateStore(
            service: PartyCreateServiceLive(),
            defaultName: defaultName,
            defaultTagline: defaultTagline,
            defaultAvatarUrl: defaultAvatarUrl,
            userLevel: userLevel
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
        .task { await store.loadInitial() }
        .sheet(isPresented: $showModePicker) {
            PartyCreateModePickerSheet(store: store) { showModePicker = false }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showLanguagePicker) {
            PartyCreateLanguagePickerSheet(store: store) { showLanguagePicker = false }
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showBackgroundPicker) {
            PartyCreateBackgroundPickerSheet(store: store) { showBackgroundPicker = false }
                .presentationDetents([.medium, .large])
        }
        .onChange(of: store.createdRoomId) { id in
            if let id, !id.isEmpty {
                store.clearCreatedRoomId()
                onCreated(id)
            }
        }
        // v7.1 gap 2: submitError toast overlay（对齐安卓失败 toast，用户看不到错误原因 → 现补 UI）
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
                Text("\(store.roomTagline.count)/\(PartyCreateStore.maxTaglineLength)")
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
                    // 已选模板 preview（v7.3：改 height=100pt 固定，宽度由 image 内在 aspect ratio 自适应）
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
            // v7.2 真机反悔：canSubmit=false 时展示缺失字段提示，帮用户定位（原按钮 disable 无反馈）
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

    /// 模板缩略图：优先服务端 imgUrl（coverImage）；否则按 videoSeatCount / seatCount 选切图
    /// v7.3：调用点用 `.frame(height: 100).fixedSize(horizontal: true, vertical: false)` 组合让
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
            Image(asset).resizable().scaledToFit()
        } else {
            Image(systemName: "square.grid.2x2")
                .resizable().scaledToFit()
                .foregroundColor(Theme.Palette.partyCreateInputCounter)
        }
    }

    /// 根据 videoSeatCount / seatCount fallback 到切图 asset 名
    static func assetNameForTemplate(_ temp: PartyRoomTemplate) -> String? {
        if let vc = temp.videoSeatCount, vc > 0 {
            switch vc {
            case 1: return "partyTemplate1Video"
            case 2: return "partyTemplate2Video"
            case 3: return "partyTemplate3Video"
            default: return nil
            }
        }
        if let sc = temp.seatCount {
            switch sc {
            case 5:  return "partyTemplate5Mic"
            case 6:  return "partyTemplate6Mic"
            case 10: return "partyTemplate10Mic"
            case 15: return "partyTemplate15Mic"
            case 20: return "partyTemplate20Mic"
            default: return nil
            }
        }
        return nil
    }
}

// MARK: - Mode picker sheet

/// H5 蓝本：`create.vue:483-514` 底部 popup + tab + 模板卡片网格 + Confirm 按钮
struct PartyCreateModePickerSheet: View {
    @ObservedObject var store: PartyCreateStore
    var onConfirm: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.Palette.partyListBackground.ignoresSafeArea()
            VStack(spacing: 16) {
                modeTab.padding(.top, 16)
                templateGrid
                Spacer(minLength: 80)
            }
            confirmButton.padding(.bottom, 20).padding(.horizontal, 20)
        }
    }

    private var modeTab: some View {
        HStack(spacing: 0) {
            tabButton(title: L10n.Party.createModeVoice, active: store.mode == PartyCreateStore.modeVoice) {
                store.mode = PartyCreateStore.modeVoice
            }
            tabButton(title: L10n.Party.createModeLiveVoice, active: store.mode == PartyCreateStore.modeLiveVoice) {
                store.mode = PartyCreateStore.modeLiveVoice
            }
        }
        .padding(4)
        .background(Capsule().fill(Theme.Palette.partyCreateInputFill))
        .padding(.horizontal, 20)
    }

    private func tabButton(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(active ? .white : Theme.Palette.partyCreateModeTabInactive)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(
                        active
                        ? AnyShapeStyle(LinearGradient(
                            colors: [Theme.Palette.partyCreateModeTabA, Theme.Palette.partyCreateModeTabB, Theme.Palette.partyCreateModeTabC],
                            startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Color.clear)
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var templateGrid: some View {
        if store.templatesLoading {
            HStack { Spacer(); ProgressView().tint(.white); Spacer() }
                .padding(.top, 40)
        } else if !store.templatesError.isEmpty {
            VStack(spacing: 8) {
                Text(store.templatesError)
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
                Button(L10n.Party.retry) { Task { await store.loadTemplates(for: store.mode) } }
                    .foregroundColor(.white)
            }
            .padding(.top, 40)
        } else if store.templates.isEmpty {
            Text(L10n.Party.createTemplateEmpty)
                .font(.system(size: 13))
                .foregroundColor(Theme.Palette.partyGreeting)
                .padding(.top, 40)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(store.templates) { temp in
                        templateCard(temp)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func templateCard(_ temp: PartyRoomTemplate) -> some View {
        // v6：对齐安卓无等级门槛，全部模板都可选；去除 lock/unlock label + 锁 icon + opacity
        // v7.2 真机反悔：图片渲染改三层 fallback（coverImage URL → asset name → placeholder），
        // 防 videoSeatCount/seatCount 不在 asset 集合时 card 全空
        let selected = store.selectedTemplate?.id == temp.id
        return Button {
            store.selectTemplate(temp)
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let cover = temp.coverImage, !cover.isEmpty, let u = URL(string: cover) {
                        CachedAsyncImage(url: u, contentMode: .fill, cdn: (.avatarLarge, .fill)) {
                            Rectangle().fill(Theme.Palette.partyCreateTempFill)
                        }
                    } else if let asset = PartyCreateRoomView.assetNameForTemplate(temp) {
                        Image(asset).resizable().scaledToFill()
                    } else {
                        Image(systemName: "square.grid.2x2")
                            .resizable().scaledToFit()
                            .foregroundColor(Theme.Palette.partyCreateInputCounter)
                            .padding(20)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if selected {
                    Image("partyTemplateSelected")
                        .resizable()
                        .frame(width: 22, height: 22)
                        .padding(6)
                }
            }
            // v7.7：固定 grid item 高度 140pt（对齐用户"固定大小"要求）—— aspectRatio(.fit) 在
            // LazyVGrid flex column 里会让高度崩塌到 0 造成堆叠；改为 flex 宽 + fixed height
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.Palette.partyCreateTempFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Theme.Palette.partyCreateTempSelected : Color.clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var confirmButton: some View {
        Button(action: onConfirm) {
            HStack {
                Spacer()
                Text(L10n.Party.createConfirm)
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
        }
        .buttonStyle(.plain)
        .disabled(store.selectedTemplate == nil)
        .opacity(store.selectedTemplate == nil ? 0.5 : 1)
    }
}

// MARK: - Language picker sheet

struct PartyCreateLanguagePickerSheet: View {
    @ObservedObject var store: PartyCreateStore
    var onDone: () -> Void

    var body: some View {
        ZStack {
            Theme.Palette.partyListBackground.ignoresSafeArea()
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
/// 视觉：3 列缩略图 grid + 选中态紫粉描边 + 底部 Confirm。
struct PartyCreateBackgroundPickerSheet: View {
    @ObservedObject var store: PartyCreateStore
    var onConfirm: () -> Void

    private let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.Palette.partyListBackground.ignoresSafeArea()
            VStack(spacing: 12) {
                Text(L10n.Party.createSectionBackground)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.top, 16)
                content
                Spacer(minLength: 80)
            }
            confirmButton.padding(.bottom, 20).padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.backgroundsLoading && store.backgrounds.isEmpty {
            HStack { Spacer(); ProgressView().tint(.white); Spacer() }
                .padding(.top, 40)
        } else if store.backgrounds.isEmpty {
            Text(L10n.Party.createBgEmpty)
                .font(.system(size: 13))
                .foregroundColor(Theme.Palette.partyGreeting)
                .padding(.top, 40)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(store.backgrounds) { bg in
                        backgroundCard(bg)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func backgroundCard(_ bg: PartyBackground) -> some View {
        let selected = store.selectedBackground?.id == bg.id
        return Button {
            store.selectedBackground = bg
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let urlStr = bg.imgUrl ?? bg.bigImgUrl,
                       !urlStr.isEmpty,
                       let u = URL(string: urlStr) {
                        CachedAsyncImage(url: u, contentMode: .fill, persistent: true, cdn: (.avatarLarge, .fill)) {
                            Rectangle().fill(Theme.Palette.partyCreateTempFill)
                        }
                    } else {
                        Rectangle().fill(Theme.Palette.partyCreateTempFill)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                if selected {
                    Image("partyTemplateSelected")
                        .resizable()
                        .frame(width: 20, height: 20)
                        .padding(6)
                }
                if !bg.isPermanent, let d = bg.duration, d > 0 {
                    Text("\(d)s")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            // v7.7：固定 grid item 高度 160pt（3:4 竖向感觉）—— aspectRatio(.fit) 会让 LazyVGrid
            // flex column 里高度崩塌到 0 造成堆叠；改 flex 宽 + fixed height 保证每行 3 格一致
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Theme.Palette.partyCreateTempSelected : Color.clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var confirmButton: some View {
        Button(action: onConfirm) {
            HStack {
                Spacer()
                Text(L10n.Party.createConfirm)
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
        }
        .buttonStyle(.plain)
        .disabled(store.selectedBackground == nil)
        .opacity(store.selectedBackground == nil ? 0.5 : 1)
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
