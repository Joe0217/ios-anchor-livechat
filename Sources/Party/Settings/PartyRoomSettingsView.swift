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
            Theme.Palette.partyListBackground.ignoresSafeArea()
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
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showBackgroundPicker) {
            settingsBackgroundPickerSheet
                .presentationDetents([.medium, .large])
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
                        bgThumbnail(bg, big: true)
                            .frame(maxWidth: .infinity)
                            .frame(height: 140)
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
            Theme.Palette.partyListBackground.ignoresSafeArea()
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

    // MARK: - Background picker sheet（选完即时保存）

    private var settingsBackgroundPickerSheet: some View {
        ZStack {
            Theme.Palette.partyListBackground.ignoresSafeArea()
            VStack(spacing: 12) {
                Text(L10n.Party.createSectionBackground)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.top, 16)
                if store.backgrounds.isEmpty {
                    Text(L10n.Party.createBgEmpty)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.Palette.partyGreeting)
                        .padding(.top, 40)
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                            ForEach(store.backgrounds) { bg in
                                bgCard(bg)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .scrollIndicators(.hidden)
                }
                Spacer(minLength: 40)
            }
        }
    }

    private func bgCard(_ bg: PartyBackground) -> some View {
        let selected = store.selectedBackground?.id == bg.id
        return Button {
            Task {
                await store.selectBackground(bg)
                showBackgroundPicker = false
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                bgThumbnail(bg, big: false)
                    .aspectRatio(0.75, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if selected {
                    Image("partyTemplateSelected")
                        .resizable().frame(width: 20, height: 20).padding(6)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Theme.Palette.partyCreateTempSelected : Color.clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func bgThumbnail(_ bg: PartyBackground, big: Bool) -> some View {
        let urlStr = big ? (bg.bigImgUrl ?? bg.imgUrl) : (bg.imgUrl ?? bg.bigImgUrl)
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
