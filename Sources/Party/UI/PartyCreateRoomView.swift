import SwiftUI

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
    @State private var lockedToast: String? = nil
    @Environment(\.dismiss) private var dismiss

    /// 默认构造 —— 提供给 PartyTabRootView 用（Live service 内部构造）
    init(defaultName: String = "", defaultTagline: String = "Let's chat and have fun together.", userLevel: Int = 0, onCreated: @escaping (String) -> Void = { _ in }) {
        _store = StateObject(wrappedValue: PartyCreateStore(
            service: PartyCreateServiceLive(),
            defaultName: defaultName,
            defaultTagline: defaultTagline,
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

            ScrollView {
                VStack(spacing: 20) {
                    avatarBlock.padding(.top, 20)
                    sectionName
                    sectionTagline
                    sectionLanguage
                    sectionMode
                    Color.clear.frame(height: 80)   // 底部 Create 按钮预留空间
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)

            createButton.padding(.bottom, 20).padding(.horizontal, 20)
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
        .overlay(alignment: .top) {
            if let t = lockedToast {
                Text(t)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .padding(.top, 12)
                    .transition(.opacity)
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        lockedToast = nil
                    }
            }
        }
        .onChange(of: store.createdRoomId) { id in
            if let id, !id.isEmpty {
                store.clearCreatedRoomId()
                onCreated(id)
            }
        }
    }

    // MARK: - Avatar block

    private var avatarBlock: some View {
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
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.white.opacity(0.5))
                )

            Circle()
                .fill(Theme.Palette.partyCreateAvatarCameraBg)
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "camera.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                )
                .offset(x: -8, y: -4)
                .accessibilityLabel("Change avatar")
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Sections

    private var sectionName: some View {
        section(title: L10n.Party.createSectionName) {
            HStack {
                TextField(L10n.Party.createNamePlaceholder, text: $store.roomName)
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
                    // 已选模板 preview
                    if let temp = store.selectedTemplate {
                        Divider().background(Theme.Palette.partyCardBorder)
                        HStack {
                            Spacer()
                            templateThumbnail(temp)
                                .frame(width: 180, height: 120)
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
    @ViewBuilder
    private func templateThumbnail(_ temp: PartyRoomTemplate) -> some View {
        if let url = temp.coverImage, !url.isEmpty, let u = URL(string: url) {
            CachedAsyncImage(url: u, persistent: true, cdn: (.avatarSmall, .fill)) {
                Color.clear
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
    @State private var lockedToast: String? = nil

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
        .overlay(alignment: .top) {
            if let t = lockedToast {
                Text(t)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .padding(.top, 60)
                    .transition(.opacity)
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        lockedToast = nil
                    }
            }
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
                Button(L10n.Party.retry) { Task { await store.loadTemplates() } }
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
        let selected = store.selectedTemplate?.id == temp.id
        let unlocked = store.isUnlocked(temp)
        return Button {
            if let msg = store.selectTemplate(temp) {
                lockedToast = msg
            }
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    PartyCreateRoomView.assetNameForTemplate(temp).map {
                        Image($0).resizable().scaledToFit()
                    }
                    if selected {
                        Image("partyTemplateSelected")
                            .resizable()
                            .frame(width: 22, height: 22)
                            .padding(6)
                    }
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 4) {
                    Image(systemName: unlocked ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.6))
                    let level = temp.createRoomLevel ?? 0
                    Text(String(format: unlocked ? L10n.Party.createModeUnlockFormat : L10n.Party.createModeLockFormat, level))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.bottom, 8)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.Palette.partyCreateTempFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Theme.Palette.partyCreateTempSelected : Color.clear, lineWidth: 1.5)
            )
            .opacity(unlocked ? 1 : 0.5)
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
