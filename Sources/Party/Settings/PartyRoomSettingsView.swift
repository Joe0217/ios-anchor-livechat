import SwiftUI
import PhotosUI

/// 房主派对房设置页（对齐 H5 create.vue 编辑态 + 安卓 Room Settings）。
///
/// 5 字段编辑：房名 / Tagline / 头像 / 语言 / 背景 + Set as Admin 入口。
/// 保存策略：只传 diff。背景是独立 setter（选完 sheet 就即时保存）。
///
/// `onSaved(snapshot)` v8.2：保存成功回传实际已保存的字段（nil 表示未变化），
/// 供上层同步 `PartyStore.roomInfo` —— 顶栏立即刷新，不必等下次 enter/IM 广播。
struct PartyRoomSettingsView: View {
    @StateObject var store: PartyRoomSettingsStore
    var onSaved: (PartyRoomSettingsSnapshot) -> Void

    @State private var showLanguagePicker = false
    @State private var showBackgroundPicker = false
    @State private var showAdminManagement = false
    @State private var photoPickerItem: PhotosPickerItem? = nil
    @FocusState private var textFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(store: PartyRoomSettingsStore, onSaved: @escaping (PartyRoomSettingsSnapshot) -> Void = { _ in }) {
        _store = StateObject(wrappedValue: store)
        self.onSaved = onSaved
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear.ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { textFieldFocused = false }

            ScrollView {
                VStack(spacing: 20) {
                    avatarBlock.padding(.top, 20)
                    sectionName
                    sectionTagline
                    sectionLanguage
                    sectionBackground
                    sectionAdmin
                    Color.clear.frame(height: 80)
                }
                .padding(.horizontal, 20)
                .contentShape(Rectangle())
                .onTapGesture { textFieldFocused = false }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)

            confirmButton.padding(.bottom, 20).padding(.horizontal, 20)
        }
        .navigationTitle(L10n.Party.settingsNavTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Theme.Palette.partyListBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await store.loadInitial() }
        .sheet(isPresented: $showLanguagePicker) {
            settingsLanguagePickerSheet
                .giftPanelSheetBackground()
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showBackgroundPicker) {
            // v7.14 抽公共组件 —— create 侧同款 UI 复用，避免"一处修 pattern 另一处漏"（v7.13 教训）
            // Confirm 交互：selected 本地暂存，Confirm 时才调 store.selectBackground async 保存
            PartyBackgroundPickerSheet(
                backgrounds: store.backgrounds,
                // Settings store 无独立 backgroundsLoading flag（loadInitial 完成后才展示页面），
                // sheet 打开时 backgrounds 若为 [] 走空态而非 loading（与 create 侧语义略异）
                isLoading: false,
                initialSelectedId: store.selectedBackground?.id
            ) { picked in
                Task {
                    await store.selectBackground(picked)
                    showBackgroundPicker = false
                }
            }
            .giftPanelSheetBackground()
            .presentationDetents([.fraction(0.8)])
        }
        .navigationDestination(isPresented: $showAdminManagement) {
            PartyRoomAdminManagementView(store: PartyAdminStore(roomId: store.roomId))
        }
        .onChange(of: photoPickerItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await store.uploadAvatar(rawData: data)
                }
                photoPickerItem = nil
            }
        }
        .onChange(of: store.didSaveSuccessfully) { done in
            if done {
                let snapshot = store.savedDiffSnapshot()
                store.clearDidSaveSuccessfully()
                onSaved(snapshot)
                dismiss()
            }
        }
        .overlay(alignment: .top) {
            if !store.saveError.isEmpty {
                Text(store.saveError)
                    .toastStyle()
                    .transition(Toast.transition)
                    .task(id: store.saveError) {
                        try? await Task.sleep(nanoseconds: Toast.dismissDurationLongNanos)
                        store.clearSaveError()
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.saveError.isEmpty)
    }

    // MARK: - Avatar

    private var avatarBlock: some View {
        PhotosPicker(selection: $photoPickerItem, matching: .images) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .strokeBorder(
                        LinearGradient(colors: [Theme.Palette.partyCreateAvatarRing1, Theme.Palette.partyCreateAvatarRing2],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 3
                    )
                    .background(Circle().fill(Theme.Palette.partyCardFill))
                    .frame(width: 120, height: 120)
                    .overlay(avatarOverlay)

                Circle()
                    .fill(Theme.Palette.partyCreateAvatarCameraBg)
                    .frame(width: 32, height: 32)
                    .overlay(Image(systemName: "camera.fill").font(.system(size: 14)).foregroundColor(.white))
                    .offset(x: -8, y: -4)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Party.settingsChangeAvatar)
    }

    @ViewBuilder
    private var avatarOverlay: some View {
        if store.isUploadingAvatar {
            Circle().fill(Color.black.opacity(0.4))
                .overlay(ProgressView().tint(.white))
        } else if let url = store.uploadedAvatarUrl ?? store.originalAvatarUrl,
                  !url.isEmpty,
                  let u = URL(string: url) {
            CachedAsyncImage(url: u, persistent: true, cdn: (.avatarLarge, .fill)) {
                Color.clear
            }
            .clipShape(Circle())
            .padding(3)
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
                Text("\(store.roomName.count)/\(PartyRoomSettingsStore.maxNameLength)")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Palette.partyCreateInputCounter)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Capsule().fill(Theme.Palette.partyCreateInputFill))
            .overlay(Capsule().stroke(Theme.Palette.partyCreateInputBorder, lineWidth: 0.5))
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
                Text("\(store.roomTagline.count)/\(PartyRoomSettingsStore.maxTaglineLength)")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Palette.partyCreateInputCounter)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Capsule().fill(Theme.Palette.partyCreateInputFill))
            .overlay(Capsule().stroke(Theme.Palette.partyCreateInputBorder, lineWidth: 0.5))
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
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.Palette.partyCreateChevron)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(Capsule().fill(Theme.Palette.partyCreateInputFill))
                .overlay(Capsule().stroke(Theme.Palette.partyCreateInputBorder, lineWidth: 0.5))
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
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.Palette.partyCreateChevron)
                    }
                    if let bg = store.selectedBackground {
                        Divider().background(Theme.Palette.partyCardBorder)
                        bgThumbnail(bg)
                            .frame(maxWidth: .infinity)
                            .frame(height: 140)
                            // CachedAsyncImage 默认 contentMode=.fill —— 缺 .clipped() 会让 image
                            // 撑大后超出 140h 参与 VStack 布局；.clipShape 只 clip 视觉不 clip layout。
                            // 顺序：.clipped() 在 .clipShape 前（先硬矩形 clip layout，再圆角 clip 视觉）
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.Palette.partyCreateInputFill))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.Palette.partyCreateInputBorder, lineWidth: 0.5))
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var sectionAdmin: some View {
        section(title: L10n.Party.settingsSectionAdmin) {
            Button {
                showAdminManagement = true
            } label: {
                HStack {
                    Text(L10n.Party.settingsManageAdmins)
                        .foregroundColor(Theme.Palette.partyCreateInputText)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.Palette.partyCreateChevron)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(Capsule().fill(Theme.Palette.partyCreateInputFill))
                .overlay(Capsule().stroke(Theme.Palette.partyCreateInputBorder, lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Confirm

    private var confirmButton: some View {
        Button {
            Task { await store.save() }
        } label: {
            HStack {
                Spacer()
                if store.isSaving { ProgressView().tint(.white).padding(.trailing, 6) }
                Text(L10n.Party.createConfirm)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.vertical, 14)
            .background(Capsule().fill(
                LinearGradient(
                    colors: [Theme.Palette.partyCreateBtnA, Theme.Palette.partyCreateBtnB],
                    startPoint: .leading, endPoint: .trailing
                )
            ))
            .opacity(store.canSave ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!store.canSave)
    }

    // MARK: - Language picker sheet

    private var settingsLanguagePickerSheet: some View {
        ZStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.languages) { lang in
                        Button {
                            store.selectedLanguage = lang
                            showLanguagePicker = false
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
                            .padding(.horizontal, 20).padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().background(Theme.Palette.partyCardBorder)
                    }
                }
            }
        }
    }

    // MARK: - Background thumbnail（sectionBackground row 已选背景大图预览用）
    //
    // v7.14：Background picker sheet UI 抽到公共组件 PartyBackgroundPickerSheet；
    // 本地只保留 sectionBackground row 已选背景大图预览的 thumbnail helper。

    @ViewBuilder
    private func bgThumbnail(_ bg: PartyBackground) -> some View {
        // sectionBackground row 大图预览：优先 bigImgUrl fallback imgUrl
        let urlStr = bg.bigImgUrl ?? bg.imgUrl
        if let url = urlStr, !url.isEmpty, let u = URL(string: url) {
            CachedAsyncImage(url: u, persistent: true, cdn: (.avatarLarge, .fill)) {
                Rectangle().fill(Theme.Palette.partyCreateTempFill)
            }
        } else {
            Rectangle().fill(Theme.Palette.partyCreateTempFill)
                .overlay(Image(systemName: "photo").foregroundColor(.white.opacity(0.4)))
        }
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
}
