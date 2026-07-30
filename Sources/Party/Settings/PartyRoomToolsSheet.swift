import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 派对房 tools sheet 枚举（PartyRoomView 用 enum-driven 单 sheet 切换）
enum PartyRoomToolSheetKind: String, Identifiable {
    case tools, settings, blocklist
    // spec §3 Sheet Mount Hoist 新增（swiftui-fullscreencover-hoist rule）：
    // Room Mode + Mic Application 相关 modal 全部 hoist 到 PartyRoomView 单一 enum
    case roomMode
    case roomModeConfirm
    case micApplicationList
    case micApplicationSwitchConfirm
    /// 对齐安卓 SeatRosterDialog(isAgreeOnSeatMode=true)：房主 tap "Approve" 时弹选座 sheet
    case approveSeatPicker
    // E-spec Lock Room：房主 tap Lock Room → 关 tools sheet → 350ms 后打开 .lockRoom（PartyLockRoomSheet）
    case lockRoom
    // E-spec MC Seat：房主/平台管理员 tap MC Seat → 关 tools sheet → 350ms 后打开 .mcSeat（PartyMCSeatSheet）
    case mcSeat
    // F-spec Party Call：入口在派对房主 view 的浮动圆形按钮（非 tools sheet），
    // tap 打开时 activeRoomTool = .privateCall 挂 CommonGiftPanel.callGate sheet（复用直播设置同款）
    case privateCall
    var id: String { rawValue }
}

/// 派对房「Room Tools」sheet — 房主/房管 tap 顶栏齿轮时弹起。
///
/// **对齐 H5 用户端** `livechat-h5/src/components/party/components/room-mana-popup.vue`：
/// - 底部 sheet + 3 列网格 + 顶部居中标题 "Room Tools"
/// - 各项按 role 显示（Owner-only 项：Lock Room / Room Mode / MC Seat / Settings；Owner + PlatformAdmin：MC Seat；全部房管：Music / Mic Application / Blocklist）
/// - Settings 已从"全部房管"降到 Owner-only（对齐文档 A §1"修改房间信息/背景/公告 · 仅房主"）
/// - iOS：所有可见工具项均接入实际房间操作或对应管理页。
///
/// 用 enum-driven 单 sheet 切换（tools ↔ settings）避免 iOS 16 双 sheet race。
struct PartyRoomToolsSheet: View {
    /// 房主 or 平台管理员判定（决定 Owner-only 项可见）
    let isOwner: Bool
    /// 平台管理员（非房主）判定（MC Seat 也允许）
    let isPlatformAdmin: Bool
    /// 工具点击仅用于埋点；由父层 fire-and-forget 处理，绝不参与工具的业务分支。
    let onTrackToolTap: (String) -> Void
    let onTapSettings: () -> Void
    let onTapBlocklist: () -> Void
    /// spec §3 wire：Room Mode item tap → 关本 sheet + 350ms 后打开 activeRoomTool = .roomMode
    let onTapRoomMode: () -> Void
    /// H5 room-mana-popup：直接开启或关闭 Mic Application。
    let onTapMicApplication: () -> Void
    /// H5 room-mana-popup 的四个状态项均从当前房态派生。
    let isRoomLocked: Bool
    let isMicApplicationOn: Bool
    let isMusicAvailable: Bool
    let isMusicEnabled: Bool
    let isMCSeatEnabled: Bool
    let onTapMusic: () -> Void
    /// E-spec Lock Room wire：房主 tap Lock Room → 关本 sheet + 350ms 后打开 activeRoomTool = .lockRoom
    let onTapLockRoom: () -> Void
    /// E-spec MC Seat wire：房主/平台管理员 tap MC Seat → 关本 sheet + 350ms 后打开 activeRoomTool = .mcSeat
    let onTapMCSeat: () -> Void
    private let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 20), count: 3)

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Text(L10n.Party.settingsToolsTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.top, 4)
                .padding(.bottom, 12)
                LazyVGrid(columns: columns, spacing: 24) {
                    if isOwner {
                        toolItem(
                            icon: isRoomLocked ? "lock.fill" : "lock.open.fill",
                            label: L10n.Party.toolLockRoom,
                            isOn: isRoomLocked
                        ) {
                            onTrackToolTap("lockRoom")
                            onTapLockRoom()
                        }
                    }
                    if isMusicAvailable {
                        toolItem(
                            icon: "music.note",
                            label: L10n.Party.toolMusic,
                            isOn: isMusicEnabled
                        ) {
                            onTrackToolTap("music")
                            onTapMusic()
                        }
                    }
                    // Settings 仅房主可见（对齐文档 A §1"修改房间信息/背景/公告 · 仅房主"；房管禁止改房间信息）
                    // android 亦通过入口 gate（PartyRoomSettingActivity.kt），非在 view 内自持角色
                    if isOwner {
                        toolItem(icon: "gearshape.fill", label: L10n.Party.toolSettings, isPrimary: true) {
                            onTrackToolTap("settings")
                            onTapSettings()
                        }
                    }
                    // H5 关闭态仍显示该入口，并以 OFF 告知房主可直接开启。
                    toolItem(
                        icon: isMicApplicationOn ? "hand.raised.fill" : "hand.raised.slash.fill",
                        label: L10n.Party.toolMicApplication,
                        isOn: isMicApplicationOn
                    ) {
                        onTrackToolTap("micApplication")
                        onTapMicApplication()
                    }
                    if isOwner {
                        toolItem(icon: "square.grid.2x2.fill", label: L10n.Party.toolRoomMode) {
                            onTrackToolTap("roomMode")
                            onTapRoomMode()
                        }
                    }
                    toolItem(icon: "person.crop.circle.badge.minus", label: L10n.Party.toolBlocklist) {
                        onTrackToolTap("blocklist")
                        onTapBlocklist()
                    }
                    if isOwner || isPlatformAdmin {
                        toolItem(
                            icon: isMCSeatEnabled ? "mic.fill" : "mic.slash.fill",
                            label: L10n.Party.toolMCSeat,
                            isOn: isMCSeatEnabled
                        ) {
                            onTrackToolTap("mcSeat")
                            onTapMCSeat()
                        }
                    }
                    // F-spec Party Call：入口在派对房主 view 浮动按钮（非 tools sheet），此处不放 icon
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
        }
    }

    private func toolItem(
        icon: String,
        label: String,
        isPrimary: Bool = false,
        isOn: Bool? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(
                            isPrimary
                            ? AnyShapeStyle(LinearGradient(
                                colors: [Theme.Palette.partyCreateBtnA, Theme.Palette.partyCreateBtnB],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                            : AnyShapeStyle(Color.white.opacity(0.08))
                        )
                        .frame(width: 48, height: 48)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                    if let isOn {
                        Text(isOn ? "ON" : "OFF")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(isOn
                                ? Color(red: 16 / 255, green: 244 / 255, blue: 150 / 255)
                                : Color(red: 149 / 255, green: 140 / 255, blue: 179 / 255)))
                            .offset(x: 16, y: -16)
                    }
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Room music (H5 music-mini-widget.vue / music-list.vue)

/// 房间右下角的音乐入口。管理者打开音乐面板，普通用户只切换本端是否收听音乐流。
struct PartyMusicMiniWidget: View {
    let settings: PartyMusicSettings
    let isAudible: Bool
    let onTap: () -> Void

    var body: some View {
        if settings.isEnabled {
            Button(action: onTap) {
                VStack(spacing: 3) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.17, green: 0.10, blue: 0.38).opacity(0.9))
                            .frame(width: 38, height: 38)
                        Image(systemName: isAudible ? "music.note" : "speaker.slash.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .rotationEffect(.degrees(settings.playStatus == 1 && isAudible ? 360 : 0))
                            .animation(
                                settings.playStatus == 1 && isAudible
                                ? .linear(duration: 2).repeatForever(autoreverses: false)
                                : .default,
                                value: settings.playStatus == 1 && isAudible
                            )
                    }
                    if let name = settings.songName, !name.isEmpty {
                        Text(name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .frame(width: 58)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.3)))
                    }
                }
                .frame(width: 68)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.Party.toolMusic)
        }
    }
}

/// 音乐管理面板。结构对齐 H5：Playlist / Local / Liked，底部保持当前曲目控制。
struct PartyMusicManagementSheet: View {
    enum Tab: Int, CaseIterable, Identifiable {
        case playlist = 1, local = 3, liked = 2

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .playlist: return L10n.Party.musicPlaylist
            case .local: return L10n.Party.musicLocal
            case .liked: return L10n.Party.musicLiked
            }
        }
    }

    @ObservedObject var store: PartyStore
    @State private var tab: Tab = .playlist
    @State private var records: [Tab: [PartyMusicItem]] = [:]
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var hasMore: [Tab: Bool] = [:]
    @State private var volume: Double
    @State private var showLocalManager = false

    init(store: PartyStore) {
        self.store = store
        _volume = State(initialValue: Double(store.roomMusicSettings.volume))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabs
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            playerControls
        }
        .padding(.top, 12)
        .task { await load(reset: true) }
        .onChange(of: tab) { _ in
            Task { await load(reset: records[tab] == nil) }
        }
        .onChange(of: store.roomMusicSettings.volume) { value in
            volume = Double(value)
        }
        .sheet(isPresented: $showLocalManager) {
            PartyLocalMusicManagementSheet(store: store) {
                Task { await load(reset: true) }
            }
            .giftPanelSheetBackground()
            .presentationDetents([.fraction(0.75), .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        HStack {
            Text(L10n.Party.musicTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            if tab == .local {
                Button { showLocalManager = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Party.musicEdit)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { item in
                Button { tab = item } label: {
                    Text(item.title)
                        .font(.system(size: 13, weight: tab == item ? .semibold : .medium))
                        .foregroundColor(.white.opacity(tab == item ? 1 : 0.55))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(tab == item ? Theme.Palette.partyCreateBtnA : .clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.24)))
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var list: some View {
        let items = records[tab] ?? []
        if isLoading && items.isEmpty {
            ProgressView().tint(.white)
        } else if items.isEmpty {
            Text(L10n.Party.musicEmpty)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.55))
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        musicRow(item: item, index: index)
                        Divider().overlay(Color.white.opacity(0.08))
                    }
                    if hasMore[tab] == true {
                        Button {
                            Task { await loadMore() }
                        } label: {
                            if isLoadingMore {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(height: 42)
                    }
                }
                .padding(.horizontal, 18)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func musicRow(item: PartyMusicItem, index: Int) -> some View {
        let isCurrent = store.roomMusicSettings.currentSongId == item.id
            && store.roomMusicSettings.musicType == tab.rawValue
        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 22)

            Button {
                Task { await store.playRoomMusic(item) }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.songName.isEmpty ? "--" : item.songName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(isCurrent ? Color(red: 1, green: 0.25, blue: 0.68) : .white)
                        .lineLimit(1)
                    Text(Self.durationText(item.durationSeconds))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                toggleLike(item, index: index)
            } label: {
                Image(systemName: item.isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(item.isLiked ? Color(red: 1, green: 0.22, blue: 0.58) : .white.opacity(0.65))
                    .frame(width: 36, height: 40)
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: 56)
    }

    private var playerControls: some View {
        let settings = store.roomMusicSettings
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: settings.playStatus == 1 ? "music.note" : "music.note.list")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                Text(settings.songName?.isEmpty == false ? settings.songName! : "--")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                Button {
                    Task { await store.cycleRoomMusicPlayMode() }
                } label: {
                    Image(systemName: playModeIcon(settings.playMode))
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                Button {
                    Task { await store.toggleRoomMusicPlayback() }
                } label: {
                    Image(systemName: settings.playStatus == 1 ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Theme.Palette.partyCreateBtnA))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Image(systemName: volume <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.7))
                Slider(value: $volume, in: 0...200, step: 1, onEditingChanged: { editing in
                    guard !editing else { return }
                    Task { await store.updateRoomMusicVolume(Int(volume)) }
                })
                .tint(Color(red: 1, green: 0.18, blue: 0.58))
                Text("\(Int(volume / 2))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.65))
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(Color.black.opacity(0.25))
    }

    private func load(reset: Bool) async {
        guard !isLoading else { return }
        if !reset, records[tab] != nil { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let items = try await PartyAPI.getMusicList(musicType: tab.rawValue)
            records[tab] = items
            hasMore[tab] = items.count >= 20
        } catch {
            AppLogger.party.notice("[PartyMusic] load list failed: \(String(describing: error), privacy: .private)")
            records[tab] = []
            hasMore[tab] = false
        }
    }

    private func loadMore() async {
        guard !isLoadingMore,
              let current = records[tab],
              let offset = current.last?.sortWeight,
              !offset.isEmpty else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let more = try await PartyAPI.getMusicList(musicType: tab.rawValue, offset: offset)
            records[tab, default: []].append(contentsOf: more)
            hasMore[tab] = more.count >= 20
        } catch {
            AppLogger.party.notice("[PartyMusic] load more failed: \(String(describing: error), privacy: .private)")
        }
    }

    private func toggleLike(_ item: PartyMusicItem, index: Int) {
        let targetLiked = !item.isLiked
        Task {
            do {
                try await PartyAPI.setMusicLiked(songId: item.id, musicType: tab.rawValue, liked: targetLiked)
                if tab == .liked && !targetLiked {
                    records[tab]?.removeAll { $0.id == item.id }
                } else if records[tab]?.indices.contains(index) == true {
                    records[tab]?[index] = item.updating(isLiked: targetLiked)
                }
            } catch {
                AppLogger.party.notice("[PartyMusic] update like failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    private func playModeIcon(_ mode: Int) -> String {
        switch mode {
        case 2: return "shuffle"
        case 3: return "repeat.1"
        default: return "repeat"
        }
    }

    fileprivate static func durationText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", max(seconds, 0) / 60, max(seconds, 0) % 60)
    }
}

/// H5 Local Music 编辑页：上传一个音频或选择多首后删除。
private struct PartyLocalMusicManagementSheet: View {
    @ObservedObject var store: PartyStore
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var items: [PartyMusicItem] = []
    @State private var selectedIDs = Set<String>()
    @State private var isEditing = false
    @State private var isLoading = false
    @State private var showFileImporter = false

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .task { await load() }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                if await store.uploadLocalRoomMusic(fileURL: url) {
                    await load()
                    onChanged()
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Button(action: dismiss.callAsFunction) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            Text(L10n.Party.musicLocal)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            Button {
                isEditing.toggle()
                selectedIDs.removeAll()
            } label: {
                Text(isEditing ? L10n.Party.cancel : L10n.Party.musicEdit)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(minWidth: 48, minHeight: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().tint(.white)
        } else if items.isEmpty {
            Text(L10n.Party.musicEmpty)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.55))
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        Button {
                            guard isEditing else { return }
                            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
                            else { selectedIDs.insert(item.id) }
                        } label: {
                            HStack(spacing: 12) {
                                if isEditing {
                                    Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundColor(selectedIDs.contains(item.id) ? Theme.Palette.partyCreateBtnA : .white.opacity(0.5))
                                }
                                Text(item.songName.isEmpty ? "--" : item.songName)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                Spacer()
                                Text(PartyMusicManagementSheet.durationText(item.durationSeconds))
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            .padding(.horizontal, 18)
                            .frame(height: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if isEditing {
                Button {
                    if selectedIDs.count == items.count { selectedIDs.removeAll() }
                    else { selectedIDs = Set(items.map(\.id)) }
                } label: {
                    Text(L10n.Party.musicSelectAll)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    let ids = Array(selectedIDs)
                    Task {
                        if await store.deleteLocalRoomMusic(ids: ids) {
                            selectedIDs.removeAll()
                            await load()
                            onChanged()
                        }
                    }
                } label: {
                    Text(L10n.Party.musicDelete)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(selectedIDs.isEmpty ? Color.white.opacity(0.12) : Color.red.opacity(0.8))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(selectedIDs.isEmpty)
            } else {
                Button { showFileImporter = true } label: {
                    HStack(spacing: 8) {
                        if store.isUploadingRoomMusic { ProgressView().tint(.white) }
                        Image(systemName: "arrow.up.circle.fill")
                        Text(L10n.Party.musicUpload)
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(LinearGradient(
                        colors: [Theme.Palette.partyCreateBtnA, Theme.Palette.partyCreateBtnB],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(store.isUploadingRoomMusic)
            }
        }
        .padding(16)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await PartyAPI.getMusicList(musicType: 3, pageSize: 100, offset: "0")
        } catch {
            items = []
            AppLogger.party.notice("[PartyMusic] load local list failed: \(String(describing: error), privacy: .private)")
        }
    }
}

// MARK: - Footer tools (H5 party-tool-menu.vue)

/// H5 幸运数字的房间级状态。菜单与设置页共用同一实例，避免打开设置时重复请求配置。
@MainActor
final class PartyLuckyNumberStore: ObservableObject {
    @Published private(set) var config: PartyLuckyNumberConfig?
    @Published private(set) var isLoadingConfig = false
    @Published private(set) var isGenerating = false
    @Published private(set) var isSaving = false
    @Published private(set) var history: [PartyLuckyNumberHistoryItem] = []
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var hasMoreHistory = false

    private var configRoomId = ""
    private var historyRoomId = ""
    private var nextHistoryPage = 1
    private var configRequestId = UUID()
    private var historyRequestId = UUID()

    func loadConfig(roomId: String, force: Bool = false) async {
        guard !roomId.isEmpty else { return }
        let roomChanged = configRoomId != roomId
        if roomChanged {
            configRoomId = roomId
            config = nil
        }
        guard force || config == nil else { return }
        guard !isLoadingConfig || roomChanged else { return }

        let requestId = UUID()
        configRequestId = requestId
        isLoadingConfig = true
        defer {
            if configRequestId == requestId {
                isLoadingConfig = false
            }
        }
        do {
            let loaded = try await PartyAPI.getLuckyNumberConfig(roomId: roomId)
            guard configRequestId == requestId else { return }
            config = loaded
        } catch is CancellationError {
            return
        } catch {
            AppLogger.party.error("[PartyLuckyNumber] load config failed: \(String(describing: error), privacy: .private)")
        }
    }

    func generate(roomId: String, hostId: String?) async -> Bool {
        guard !roomId.isEmpty, !isGenerating else { return false }
        isGenerating = true
        defer { isGenerating = false }
        // 对齐 H5：用户有效点击即入队，不等待生成接口成功，且不阻塞请求。
        PartyAnalytics.track(
            "b_lucky_number_click",
            properties: trackingProperties(roomId: roomId, hostId: hostId)
        )
        do {
            let generated = try await PartyAPI.generateLuckyNumber(roomId: roomId)
            return generated
        } catch is CancellationError {
            return false
        } catch {
            AppLogger.party.error("[PartyLuckyNumber] generate failed: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    func save(
        roomId: String,
        numberRangeCode: Int,
        luckyNumber: Int?,
        adminCanSet: Bool?
    ) async -> Bool {
        guard !roomId.isEmpty, !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            guard let saved = try await PartyAPI.saveLuckyNumberConfig(
                roomId: roomId,
                numberRangeCode: numberRangeCode,
                luckyNumber: luckyNumber,
                adminCanSet: adminCanSet
            ) else {
                return false
            }
            configRoomId = roomId
            config = saved
            return true
        } catch is CancellationError {
            return false
        } catch {
            AppLogger.party.error("[PartyLuckyNumber] save config failed: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    private func trackingProperties(roomId: String, hostId: String?) -> [String: Any] {
        [
            "roomid": roomId,
            "room_id": roomId,
            "host_id": hostId ?? "",
        ]
    }

    func loadHistory(roomId: String, reset: Bool = false) async {
        guard !roomId.isEmpty else { return }
        let shouldReset = historyRoomId != roomId || reset
        guard !isLoadingHistory || shouldReset else { return }
        if shouldReset {
            resetHistory()
            historyRoomId = roomId
        } else if !hasMoreHistory {
            return
        }

        let requestPage = nextHistoryPage
        let requestId = UUID()
        historyRequestId = requestId
        isLoadingHistory = true
        defer {
            if historyRequestId == requestId {
                isLoadingHistory = false
            }
        }
        do {
            let response = try await PartyAPI.getLuckyNumberHistory(roomId: roomId, pageNo: requestPage)
            guard historyRequestId == requestId else { return }
            history.append(contentsOf: response.records)
            nextHistoryPage = response.pageNo + 1
            hasMoreHistory = history.count < response.total
        } catch is CancellationError {
            return
        } catch {
            AppLogger.party.error("[PartyLuckyNumber] load history failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// H5 clears the list and its paging state whenever the history popup closes or unmounts.
    /// Invalidating the request identifier also prevents a late response from repopulating a dismissed sheet.
    func resetHistory() {
        historyRequestId = UUID()
        history = []
        isLoadingHistory = false
        hasMoreHistory = false
        historyRoomId = ""
        nextHistoryPage = 1
    }
}

/// 底部 Tools 面板：结构、可见性与 H5 `party-tool-menu.vue` 对齐。
struct PartyRoomToolMenuSheet: View {
    @ObservedObject var luckyNumberStore: PartyLuckyNumberStore
    let roomId: String
    let hostId: String?
    let showPk: Bool
    let showSuperWheel: Bool
    let isRoomMuted: Bool
    let onStartPk: () -> Void
    let onOpenSuperWheel: () -> Void
    let onToggleRoomMute: () -> Void
    let onOpenLuckyNumberSettings: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                interactiveGames
                basicTools
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 18)
        }
        .task(id: roomId) {
            await luckyNumberStore.loadConfig(roomId: roomId)
        }
    }

    private var interactiveGames: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.PartyRoom.toolMenuInteractiveGames)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            HStack(alignment: .top, spacing: 12) {
                if showPk {
                    Button {
                        dismiss()
                        onStartPk()
                    } label: {
                        toolGameCard(icon: "partyPkLogo", title: L10n.PartyRoom.toolMenuPk)
                    }
                    .buttonStyle(.plain)
                }

                if showSuperWheel {
                    Button {
                        dismiss()
                        onOpenSuperWheel()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "circle.dotted.circle")
                                .font(.system(size: 34, weight: .bold))
                                .foregroundColor(Color(hex: 0xFFDD63))
                                .frame(width: 50, height: 50)
                            Text(L10n.PartyRoom.superWheelTitle)
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }
                        .frame(width: 100, height: 126)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }

                luckyNumberCard
                Spacer(minLength: 0)
            }
        }
    }

    private var luckyNumberCard: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Button {
                    Task {
                        guard await luckyNumberStore.generate(roomId: roomId, hostId: hostId) else { return }
                        dismiss()
                        AppToastCenter.shared.show(L10n.PartyRoom.toolMenuLuckyNumberSent)
                    }
                } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            // 与 H5 party-tool-menu.vue 使用同一张 50px Lucky Number 图标。
                            Image("partyLuckyNumberIcon")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 50, height: 50)
                            if luckyNumberStore.isGenerating {
                                ProgressView()
                                    .tint(.white)
                                    .frame(width: 50, height: 50)
                                    .background(Color.black.opacity(0.18), in: Circle())
                            }
                        }
                        Text(L10n.PartyRoom.toolMenuLuckyNumber)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                }
                .buttonStyle(.plain)
                .disabled(luckyNumberStore.isGenerating)

                Text(L10n.PartyRoom.toolMenuFree)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .frame(height: 16)
                    .background(Capsule().fill(Color(red: 1.0, green: 0.18, blue: 0.46)))
                    .offset(x: 4, y: -4)
            }

            if luckyNumberStore.config?.canConfigure == true {
                Button {
                    dismiss()
                    onOpenLuckyNumberSettings()
                } label: {
                    Label(L10n.PartyRoom.toolMenuSettings, systemImage: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(red: 0.29, green: 0.87, blue: 0.63))
                        .padding(.top, 8)
                        .padding(.bottom, 10)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(height: 34)
            }
        }
        .frame(width: 100)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private var basicTools: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.PartyRoom.toolMenuBasicTools)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            Button(action: onToggleRoomMute) {
                VStack(spacing: 8) {
                    Image(systemName: isRoomMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 56, height: 56)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
                    Text(L10n.PartyRoom.toolMenuRoomMute)
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                }
                .frame(width: 100)
            }
            .buttonStyle(.plain)
        }
    }

    private func toolGameCard(icon: String, title: String) -> some View {
        VStack(spacing: 8) {
            Image(icon)
                .resizable()
                .scaledToFit()
                .frame(width: 50, height: 50)
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.white)
        }
                .frame(width: 100, height: 126)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

/// 幸运数字设置页。内容与 H5 `lucky-number-panel.vue` 一致：范围、固定号码与房主的管理员授权。
struct PartyLuckyNumberSettingsSheet: View {
    @ObservedObject var luckyNumberStore: PartyLuckyNumberStore
    let roomId: String
    let isRoomOwner: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var selectedRange = 1
    @State private var fixedNumber = ""
    @State private var setNumberEnabled = true
    @State private var adminCanSet = false
    @State private var showHistory = false
    @FocusState private var isNumberFocused: Bool

    private struct RangeOption: Identifiable {
        let code: Int
        let label: String
        let max: Int
        var id: Int { code }
    }

    private let rangeOptions = [
        RangeOption(code: 1, label: "0 - 9", max: 9),
        RangeOption(code: 2, label: "0 - 99", max: 99),
        RangeOption(code: 3, label: "0 - 999", max: 999),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                if luckyNumberStore.isLoadingConfig && luckyNumberStore.config == nil {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                        .padding(.bottom, 60)
                } else {
                    editor
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 30)
        }
        .task(id: roomId) {
            await luckyNumberStore.loadConfig(roomId: roomId)
            syncForm()
        }
        .onChange(of: luckyNumberStore.config) { _ in
            syncForm()
        }
        .sheet(isPresented: $showHistory) {
            PartyLuckyNumberHistorySheet(luckyNumberStore: luckyNumberStore, roomId: roomId)
                .giftPanelSheetBackground()
                .presentationDetents([.fraction(0.7)])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Text(L10n.PartyRoom.toolMenuLuckyNumber)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            Spacer()
            if isRoomOwner {
                Button { showHistory = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.PartyRoom.toolMenuHistory)
            } else {
                Color.clear.frame(width: 28, height: 28)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 22)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.PartyRoom.toolMenuRange)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            HStack(spacing: 10) {
                ForEach(rangeOptions) { option in
                    Button {
                        selectedRange = option.code
                    } label: {
                        Text(option.label)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundColor(selectedRange == option.code ? Color(red: 1.0, green: 0.89, blue: 0.35) : .white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.white.opacity(selectedRange == option.code ? 0.10 : 0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(selectedRange == option.code ? Color(red: 0.24, green: 0.88, blue: 0.63) : .clear, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 12)

            Toggle(L10n.PartyRoom.toolMenuSetLuckyNumber, isOn: $setNumberEnabled)
                .font(.system(size: 15))
                .foregroundColor(.white)
                .tint(Color(red: 1.0, green: 0.18, blue: 0.60))
                .padding(.top, 22)

            if setNumberEnabled {
                TextField("", text: $fixedNumber)
                    .focused($isNumberFocused)
                    .keyboardType(.numberPad)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(Color(red: 1.0, green: 0.89, blue: 0.35))
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.25)))
                    .padding(.top, 12)
                    // H5 `van-field` 的 maxlength=3；先限长再走保存时数值/范围校验。
                    .onChange(of: fixedNumber) { value in
                        if value.count > 3 {
                            fixedNumber = String(value.prefix(3))
                        }
                    }
            }

            if isRoomOwner {
                Toggle(L10n.PartyRoom.toolMenuAllowAdmins, isOn: $adminCanSet)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .tint(Color(red: 1.0, green: 0.18, blue: 0.60))
                    .padding(.top, 22)
            }

            Button {
                save()
            } label: {
                HStack {
                    Spacer()
                    if luckyNumberStore.isSaving {
                        ProgressView().tint(.white)
                    }
                    Text(L10n.PartyRoom.toolMenuSave)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                }
                .frame(height: 48)
                .background(LinearGradient(
                    colors: [Color(red: 0.61, green: 0.15, blue: 0.88), Color(red: 0.94, green: 0.09, blue: 0.30)],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(luckyNumberStore.isSaving)
            .padding(.top, 34)
        }
    }

    private func syncForm() {
        guard let config = luckyNumberStore.config else { return }
        selectedRange = config.numberRangeCode
        setNumberEnabled = true
        fixedNumber = config.luckyNumber.map(String.init) ?? ""
        adminCanSet = config.adminCanSet
    }

    private func save() {
        let trimmed = fixedNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let luckyNumber: Int?
        if setNumberEnabled, !trimmed.isEmpty {
            guard trimmed.allSatisfy(\.isNumber),
                  let value = Int(trimmed),
                  value <= rangeOptions.first(where: { $0.code == selectedRange })?.max ?? 9 else {
                AppToastCenter.shared.show(L10n.PartyRoom.toolMenuInvalidLuckyNumber)
                return
            }
            luckyNumber = value
        } else {
            luckyNumber = nil
        }

        Task {
            let saved = await luckyNumberStore.save(
                roomId: roomId,
                numberRangeCode: selectedRange,
                luckyNumber: luckyNumber,
                adminCanSet: isRoomOwner ? adminCanSet : nil
            )
            guard saved else { return }
            AppToastCenter.shared.show(L10n.PartyRoom.toolMenuLuckyNumberSaved)
            dismiss()
        }
    }
}

/// 房主幸运数字历史。H5 同样只给房主在设置页内查看此入口。
struct PartyLuckyNumberHistorySheet: View {
    @ObservedObject var luckyNumberStore: PartyLuckyNumberStore
    let roomId: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .task(id: roomId) {
            await luckyNumberStore.loadHistory(roomId: roomId, reset: true)
        }
        .onDisappear {
            luckyNumberStore.resetHistory()
        }
    }

    private var header: some View {
        ZStack {
            Text(L10n.PartyRoom.toolMenuHistory)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            HStack {
                Button {
                    AppToastCenter.shared.show(L10n.PartyRoom.toolMenuHistoryHint)
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                Spacer()
                Button(action: dismiss.callAsFunction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 26)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var content: some View {
        if luckyNumberStore.isLoadingHistory && luckyNumberStore.history.isEmpty {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if luckyNumberStore.history.isEmpty {
            EmptyStateView(
                style: .full,
                text: L10n.PartyRoom.toolMenuNoHistory,
                textColor: .white.opacity(0.5),
                textFont: .system(size: 14, weight: .medium)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(luckyNumberStore.history) { item in
                        historyRow(item)
                    }
                    if luckyNumberStore.hasMoreHistory {
                        Button {
                            Task { await luckyNumberStore.loadHistory(roomId: roomId) }
                        } label: {
                            if luckyNumberStore.isLoadingHistory {
                                Text(L10n.Party.loading)
                                    .font(.system(size: 13))
                                    .foregroundColor(Color(red: 1.0, green: 229 / 255, blue: 92 / 255))
                            } else {
                                Text(L10n.PartyRoom.toolMenuLoadMore)
                                    .font(.system(size: 13))
                                    .foregroundColor(Color(red: 1.0, green: 229 / 255, blue: 92 / 255))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(luckyNumberStore.isLoadingHistory)
                        .padding(8)
                        .padding(.top, 4)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func historyRow(_ item: PartyLuckyNumberHistoryItem) -> some View {
        HStack(spacing: 12) {
            if let avatar = item.avatar, let url = URL(string: avatar) {
                CachedAsyncImage(url: url, persistent: true, cdn: (.avatarSmall, .fill)) {
                    Circle().fill(Color.white.opacity(0.12))
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "person.fill").foregroundColor(.white.opacity(0.5)))
            }
            Text(item.nickname?.isEmpty == false ? item.nickname! : "--")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer()
            LuckyNumberGradientText(value: "\(item.luckyNumber)", fontSize: 24)
        }
        .padding(.vertical, 6)
    }
}

/// 1052 幸运数字中奖个人弹窗。
/// 视觉对齐 H5 `lucky-number-win-popup.vue`：彩带、头像、昵称、中奖文案、醒目数字与确认按钮。
struct PartyLuckyNumberWinPopup: View {
    let payload: PartyLuckyNumberWinPayload
    let onDismiss: () -> Void

    private var message: String {
        if let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        return String(format: L10n.Party.luckyNumberPersonalWinFormat, payload.luckyNumber)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    Image("partyLuckyNumberWinning")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 288, height: 130)

                    AvatarView(urlString: payload.avatar, size: 72, kind: .user)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .offset(y: 36)
                }
                .frame(height: 130)
                .zIndex(1)

                VStack(spacing: 0) {
                    Text(payload.nickname.isEmpty ? "--" : payload.nickname)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(maxWidth: 220)
                        .padding(.top, 46)

                    Text(message)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                        .padding(.horizontal, 24)

                    LuckyNumberGradientText(
                        value: "\(payload.luckyNumber)",
                        fontSize: 48,
                        weight: .black
                    )
                        .padding(.top, 10)

                    Button(action: onDismiss) {
                        Text(L10n.Party.ok)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 1.0, green: 0.60, blue: 0.24), Color(red: 1.0, green: 0.18, blue: 0.61)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 22)
                }
                .frame(width: 320)
                .background(Color(red: 0.12, green: 0.05, blue: 0.25), in: RoundedRectangle(cornerRadius: 20))
                .offset(y: -56)
            }
            .frame(width: 320)
            .accessibilityElement(children: .contain)
        }
    }
}

private struct PartyLuckyNumberWinOverlayModifier: ViewModifier {
    @ObservedObject var store: PartyStore

    func body(content: Content) -> some View {
        content.overlay {
            if let payload = store.luckyNumberWinPayload {
                PartyLuckyNumberWinPopup(payload: payload) {
                    store.dismissLuckyNumberWinPopup()
                }
                .transition(.opacity)
                .zIndex(200)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.luckyNumberWinPayload?.id)
    }
}

extension View {
    func partyLuckyNumberWinOverlay(store: PartyStore) -> some View {
        modifier(PartyLuckyNumberWinOverlayModifier(store: store))
    }
}

// MARK: - Super Wheel state

enum PartySuperWheelResultKind: Equatable {
    case eliminated
    case winner
}

/// Party 房 Super Wheel 的单一状态源。HTTP 全量状态用于进房/重连对账，1150-1156 IM
/// 广播用于实时推进阶段；两条链路都归约到这里，避免 UI 直接依赖不完整的消息 payload。
@MainActor
final class PartySuperWheelStore: ObservableObject {
    static let shared = PartySuperWheelStore()

    @Published private(set) var wheelState: PartySuperWheelState?
    @Published private(set) var config: PartySuperWheelConfig?
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isConfigLoading = false
    @Published private(set) var isPerformingAction = false
    @Published var isPanelPresented = false
    @Published var isConfigPresented = false
    @Published private(set) var isPanelDismissed = false
    @Published private(set) var isResultDismissed = false

    private var countdownTask: Task<Void, Never>?
    private var shouldPresentPanelAfterConfigDismissal = false
    private var trackedRoomId: String?
    private var stateRequestSequence = 0
    private var reconciledDeadlineMs: Int64?
    private var deadlineReconciliationTask: Task<Void, Never>?

    private init() {}

    deinit { countdownTask?.cancel() }

    var isActive: Bool {
        guard let wheelState else { return false }
        return wheelState.state != 0 && wheelState.state != 9
    }

    var isSignup: Bool { wheelState?.state == 3 }
    var isBetting: Bool { wheelState?.state == 5 }
    var isSpinning: Bool { wheelState?.state == 6 }
    var isReveal: Bool { wheelState?.state == 7 }
    var isFinal: Bool { wheelState?.state == 8 }
    var entryFees: [Int] {
        let fees = config?.entryFees ?? []
        return fees.isEmpty ? [100, 300, 500] : fees
    }
    var isEnabled: Bool { config?.enabled ?? false }
    var myParticipant: PartySuperWheelParticipant? {
        guard let userId = SessionStore.shared.user?.userId else { return nil }
        return wheelState?.participants.first { $0.userId == String(userId) }
    }
    /// H5 允许 CREATED / WAITING / SIGNUP 三个前置阶段加入，不能只等到 SIGNUP。
    var canJoin: Bool {
        guard myParticipant == nil else { return false }
        return [1, 2, 3].contains(wheelState?.state ?? 0)
    }
    var canBet: Bool { isBetting && myParticipant?.status == 1 }
    var isMyParticipantAlive: Bool { myParticipant?.status == 1 }
    var isParticipant: Bool { myParticipant != nil }
    var isRegistering: Bool { [1, 2, 3].contains(wheelState?.state ?? 0) }
    var isSpectating: Bool { isActive && !isMyParticipantAlive && !canJoin }
    var shouldShowBetArea: Bool {
        isMyParticipantAlive && [5, 6, 7, 8].contains(wheelState?.state ?? 0)
    }
    var isBetDisabled: Bool { !isBetting }
    var hasBigCountdown: Bool {
        remainingSeconds > 0 && [3, 4, 5].contains(wheelState?.state ?? 0)
    }
    var myWinningRatio: Int {
        guard let mine = myParticipant else { return 0 }
        let aliveBet = wheelState?.participants
            .filter { $0.status == 1 }
            .reduce(Int64(0)) { $0 + max(0, $1.totalBet) } ?? 0
        guard aliveBet > 0 else { return 0 }
        return min(100, max(0, Int((Double(max(0, mine.totalBet)) / Double(aliveBet) * 100).rounded())))
    }
    var resultKind: PartySuperWheelResultKind? {
        if isFinal, (wheelState?.winner != nil || wheelState?.winnerId != nil) { return .winner }
        if isReveal, wheelState?.revealUser != nil { return .eliminated }
        return nil
    }
    /// 已参与的用户即使将大面板最小化，也必须收到淘汰/获胜结果；观战用户只在面板展开时展示。
    var shouldPresentResult: Bool {
        resultKind != nil && !isResultDismissed && (isParticipant || isPanelPresented)
    }

    func beginTracking(roomId: String) {
        guard !roomId.isEmpty else { return }
        guard trackedRoomId != roomId else { return }
        countdownTask?.cancel()
        countdownTask = nil
        deadlineReconciliationTask?.cancel()
        deadlineReconciliationTask = nil
        stateRequestSequence &+= 1
        trackedRoomId = roomId
        wheelState = nil
        remainingSeconds = 0
        reconciledDeadlineMs = nil
        isPanelPresented = false
        isPanelDismissed = false
        isResultDismissed = false
    }

    func prepareConfig() async {
        isConfigPresented = true
        guard !isConfigLoading else { return }
        isConfigLoading = true
        defer { isConfigLoading = false }
        do {
            config = try await PartyAPI.superWheelConfig()
        } catch {
            AppLogger.party.notice("[SuperWheel] config load failed: \(String(describing: error), privacy: .private)")
            AppToastCenter.shared.show(L10n.PartyRoom.superWheelUnavailable)
        }
    }

    func loadState(roomId: String, presentWhenActive: Bool) async {
        guard !roomId.isEmpty, trackedRoomId == roomId else { return }
        let requestSequence = { stateRequestSequence &+= 1; return stateRequestSequence }()
        isLoading = true
        defer {
            if requestSequence == stateRequestSequence {
                isLoading = false
            }
        }
        do {
            guard let response = try await PartyAPI.superWheelState(roomId: roomId) else {
                guard requestSequence == stateRequestSequence, trackedRoomId == roomId else { return }
                wheelState = nil
                isPanelPresented = false
                refreshCountdown()
                return
            }
            guard requestSequence == stateRequestSequence,
                  trackedRoomId == roomId,
                  response.roomId.isEmpty || response.roomId == roomId else { return }
            applyLoadedState(response)
            if presentWhenActive, shouldAutomaticallyPresentPanel { isPanelPresented = true }
            refreshCountdown()
        } catch {
            AppLogger.party.notice("[SuperWheel] state load failed: \(String(describing: error), privacy: .private)")
        }
    }

    func open(roomId: String, entryFee: Int) async {
        guard trackedRoomId == roomId,
              entryFees.contains(entryFee),
              !isPerformingAction else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            let opened = try await PartyAPI.openSuperWheel(roomId: roomId, entryFee: entryFee)
            wheelState = PartySuperWheelState(
                roundId: opened.roundId,
                roomId: roomId,
                hostId: SessionStore.shared.user.flatMap { user in
                    user.userId.map { String($0) }
                },
                entryFee: opened.entryFee,
                state: opened.state,
                roundNo: 0,
                totalPool: 0,
                phaseDeadlineMs: nil,
                participants: [],
                winnerId: nil,
                winner: nil,
                winnerAmount: nil,
                hostAmount: nil,
                platformAmount: nil,
                revealUser: nil,
                remainCount: nil,
                eliminatedUserId: nil,
                sectorIndex: nil
            )
            queuePanelAfterConfigDismissal()
            PartyAnalytics.track(
                "h_superwheel_start",
                properties: ["roomid": roomId, "dia": entryFee]
            )
            await loadState(roomId: roomId, presentWhenActive: false)
        } catch let apiError as PartyAPIError {
            if case .business(let code, _) = apiError, code == "11503" {
                // H5：房间已有进行中对局时不报错，直接进入当前对局。
                queuePanelAfterConfigDismissal()
                await loadState(roomId: roomId, presentWhenActive: false)
                return
            }
            AppLogger.party.notice("[SuperWheel] open failed: \(String(describing: apiError), privacy: .private)")
            AppToastCenter.shared.show(L10n.PartyRoom.superWheelActionFailed)
        } catch {
            AppLogger.party.notice("[SuperWheel] open failed: \(String(describing: error), privacy: .private)")
            AppToastCenter.shared.show(L10n.PartyRoom.superWheelActionFailed)
        }
    }

    func join() async {
        guard let wheelState, !isPerformingAction else { return }
        let trackingProperties = wheelTrackingProperties(for: wheelState)
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await PartyAPI.joinSuperWheel(roundId: wheelState.roundId)
            PartyAnalytics.track("b_wheel_fill_click", properties: trackingProperties)
            await loadState(roomId: wheelState.roomId, presentWhenActive: false)
            var resultProperties = trackingProperties
            resultProperties["state"] = "success"
            PartyAnalytics.track("b_wheel_join_click", properties: resultProperties)
        } catch {
            var resultProperties = trackingProperties
            resultProperties["state"] = "fail"
            resultProperties["reason"] = superWheelJoinFailureReason(error)
            PartyAnalytics.track("b_wheel_join_click", properties: resultProperties)
            AppLogger.party.notice("[SuperWheel] join failed: \(String(describing: error), privacy: .private)")
            AppToastCenter.shared.show(L10n.PartyRoom.superWheelActionFailed)
        }
    }

    private func wheelTrackingProperties(for state: PartySuperWheelState) -> [String: Any] {
        var properties = PartyAnalytics.roomProperties(
            roomId: state.roomId,
            ownerId: state.hostId
        )
        properties["hostid"] = state.hostId ?? ""
        properties["dia"] = state.entryFee
        return properties
    }

    private func superWheelJoinFailureReason(_ error: Error) -> String {
        guard case let PartyAPIError.business(code, _) = error, code == "1019" else {
            return "error"
        }
        return "insufficient"
    }

    /// iOS 同一展示容器不能在同一更新周期内切换两个 `.sheet`。
    /// 配置 sheet 的 onDismiss 会调用 `presentQueuedPanelAfterConfigDismissal()`。
    private func queuePanelAfterConfigDismissal() {
        isConfigPresented = false
        shouldPresentPanelAfterConfigDismissal = true
    }

    func presentQueuedPanelAfterConfigDismissal() {
        guard shouldPresentPanelAfterConfigDismissal, !isConfigPresented else { return }
        shouldPresentPanelAfterConfigDismissal = false
        openPanel()
    }

    /// 常驻图标/工具入口展开本局面板时，同时允许重新查看当前结算结果。
    func openPanel() {
        isPanelDismissed = false
        isResultDismissed = false
        isPanelPresented = true
    }

    /// 最小化不结束游戏。淘汰者和未参与者本局不再被状态同步反复拉回，已参与者仍会收到结算。
    func dismissPanel() {
        isPanelPresented = false
        isPanelDismissed = true
    }

    func dismissResult() {
        isResultDismissed = true
        dismissPanel()
    }

    func bet(amount: Int) async {
        guard let wheelState, amount > 0, !isPerformingAction else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await PartyAPI.betSuperWheel(roundId: wheelState.roundId, amount: amount)
            await loadState(roomId: wheelState.roomId, presentWhenActive: false)
        } catch {
            AppLogger.party.notice("[SuperWheel] bet failed: \(String(describing: error), privacy: .private)")
            AppToastCenter.shared.show(L10n.PartyRoom.superWheelActionFailed)
        }
    }

    func close() async {
        guard let wheelState, !isPerformingAction else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await PartyAPI.closeSuperWheel(roundId: wheelState.roundId)
            PartyAnalytics.track(
                "h_superwheel_close_success",
                properties: ["roomid": wheelState.roomId]
            )
            await loadState(roomId: wheelState.roomId, presentWhenActive: false)
        } catch {
            AppLogger.party.notice("[SuperWheel] close failed: \(String(describing: error), privacy: .private)")
            AppToastCenter.shared.show(L10n.PartyRoom.superWheelActionFailed)
        }
    }

    func applyBroadcast(attachType: Int, payload: [String: Any]) {
        guard let trackedRoomId else { return }
        guard let incomingRoundId = PartySuperWheelBroadcast.string(payload["roundId"]), !incomingRoundId.isEmpty else {
            return
        }
        let incomingRoomId = PartySuperWheelBroadcast.string(payload["roomId"])
        guard incomingRoomId == nil || incomingRoomId == trackedRoomId else { return }
        if attachType == PartyAttachType.superWheelStateSync.rawValue {
            // 1150 的基类 payload 在新局时可能不带 entryFee。先拉 /state，绝不能让 0 或上一局档位
            // 短暂出现在 Join 按钮上；这与 H5 新 roundId 的处理一致。
            guard let current = wheelState, current.roundId == incomingRoundId else {
                Task { await loadState(roomId: trackedRoomId, presentWhenActive: false) }
                return
            }
            guard var fullState = try? PartySuperWheelState.from(payload),
                  fullState.roomId.isEmpty || fullState.roomId == trackedRoomId else { return }
            if fullState.entryFee <= 0 { fullState.entryFee = current.entryFee }
            if PartySuperWheelBroadcast.array(payload["participants"]) == nil {
                fullState.participants = current.participants
            }
            applyLoadedState(fullState)
            if shouldAutomaticallyPresentPanel { isPanelPresented = true }
            refreshCountdown()
            return
        }

        guard var state = wheelState else { return }
        state.state = PartySuperWheelBroadcast.int(payload["state"]) ?? state.state
        state.roundNo = PartySuperWheelBroadcast.int(payload["roundNo"]) ?? state.roundNo
        state.totalPool = PartySuperWheelBroadcast.int64(payload["totalPool"]) ?? state.totalPool
        state.phaseDeadlineMs = PartySuperWheelBroadcast.int64(payload["phaseDeadline"]) ?? state.phaseDeadlineMs

        switch attachType {
        case PartyAttachType.superWheelSpin.rawValue:
            // H5 在转动/揭晓期间冻结盘面；不可在 1152 提前把命中者移出扇区。
            state.state = 6
            state.eliminatedUserId = PartySuperWheelBroadcast.string(payload["eliminatedUserId"])
            state.sectorIndex = PartySuperWheelBroadcast.int(payload["sectorIndex"])
        case PartyAttachType.superWheelReveal.rawValue:
            state.state = 7
            isResultDismissed = false
            state.revealUser = PartySuperWheelUser.from(payload["eliminatedUser"] as? [String: Any])
            if state.revealUser == nil,
               let userId = PartySuperWheelBroadcast.string(payload["eliminatedUserId"])
                    ?? state.eliminatedUserId,
               let participant = state.participants.first(where: { $0.userId == userId }) {
                state.revealUser = PartySuperWheelUser(
                    userId: participant.userId,
                    nickname: participant.nickname,
                    avatar: participant.avatar
                )
            }
            state.eliminatedUserId = PartySuperWheelBroadcast.string(payload["eliminatedUserId"])
                ?? state.revealUser?.userId
                ?? state.eliminatedUserId
            state.remainCount = PartySuperWheelBroadcast.int(payload["remainCount"])
            if let userId = state.revealUser?.userId,
               let index = state.participants.firstIndex(where: { $0.userId == userId }) {
                state.participants[index].status = 2
            }
        case PartyAttachType.superWheelFinal.rawValue:
            state.state = 8
            isResultDismissed = false
            state.winner = PartySuperWheelUser.from(payload["winner"] as? [String: Any])
            state.winnerId = PartySuperWheelBroadcast.string(payload["winnerId"]) ?? state.winner?.userId
            if state.winner == nil,
               let winnerId = state.winnerId,
               let participant = state.participants.first(where: { $0.userId == winnerId }) {
                state.winner = PartySuperWheelUser(
                    userId: participant.userId,
                    nickname: participant.nickname,
                    avatar: participant.avatar
                )
            }
            state.winnerAmount = PartySuperWheelBroadcast.int64(payload["winnerAmount"])
            state.hostAmount = PartySuperWheelBroadcast.int64(payload["hostAmount"])
            state.platformAmount = PartySuperWheelBroadcast.int64(payload["platformAmount"])
        case PartyAttachType.superWheelClosed.rawValue:
            state.state = 9
            isPanelPresented = false
        default:
            break
        }
        wheelState = state
        refreshCountdown()
    }

    func reset() {
        countdownTask?.cancel()
        countdownTask = nil
        deadlineReconciliationTask?.cancel()
        deadlineReconciliationTask = nil
        wheelState = nil
        config = nil
        remainingSeconds = 0
        isLoading = false
        isConfigLoading = false
        isPerformingAction = false
        shouldPresentPanelAfterConfigDismissal = false
        isPanelPresented = false
        isConfigPresented = false
        isPanelDismissed = false
        isResultDismissed = false
        trackedRoomId = nil
        stateRequestSequence &+= 1
        reconciledDeadlineMs = nil
    }

    private func refreshCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        updateRemainingSeconds()
        guard wheelState?.phaseDeadlineMs != nil, isActive else { return }
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                self?.updateRemainingSeconds()
            }
        }
    }

    private var shouldAutomaticallyPresentPanel: Bool {
        !isPanelDismissed || isMyParticipantAlive
    }

    private func applyLoadedState(_ state: PartySuperWheelState) {
        if wheelState?.roundId != state.roundId {
            isPanelDismissed = false
            isResultDismissed = false
        }
        wheelState = state
    }

    private func updateRemainingSeconds() {
        guard let deadline = wheelState?.phaseDeadlineMs else {
            remainingSeconds = 0
            return
        }
        let newRemainingSeconds = max(0, Int(ceil(Double(deadline - Int64(Date().timeIntervalSince1970 * 1_000)) / 1_000)))
        if remainingSeconds != newRemainingSeconds {
            remainingSeconds = newRemainingSeconds
        }
        guard remainingSeconds == 0,
              isActive,
              reconciledDeadlineMs != deadline,
              let roomId = trackedRoomId else { return }
        reconciledDeadlineMs = deadline
        deadlineReconciliationTask?.cancel()
        deadlineReconciliationTask = Task { [weak self, deadline, roomId] in
            guard let self else { return }
            await self.loadState(roomId: roomId, presentWhenActive: false)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled,
                  self.trackedRoomId == roomId,
                  self.wheelState?.phaseDeadlineMs == deadline,
                  self.isActive else { return }
            await self.loadState(roomId: roomId, presentWhenActive: false)
        }
    }
}

private enum PartySuperWheelBroadcast {
    static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String, !string.isEmpty { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    static func array(_ value: Any?) -> [Any]? { value as? [Any] }
}

// MARK: - Super Wheel UI

/// 房主/房管从工具栏打开的开局面板。档位和玩法开关均由服务端配置决定。
struct PartySuperWheelConfigSheet: View {
    @ObservedObject var wheelStore: PartySuperWheelStore
    let roomId: String
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFee: Int?
    @State private var showsRules = false

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text(L10n.PartyRoom.superWheelTitle)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button { showsRules = true } label: {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white.opacity(0.84))
                }
                .buttonStyle(.plain)
                Button(action: dismiss.callAsFunction) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white.opacity(0.84))
                }
                .buttonStyle(.plain)
            }

            if wheelStore.isConfigLoading && wheelStore.config == nil {
                ProgressView().tint(.white)
            } else if !wheelStore.isEnabled {
                Text(L10n.PartyRoom.superWheelUnavailable)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.7))
            } else {
                VStack(spacing: 10) {
                    ForEach(wheelStore.entryFees, id: \.self) { fee in
                        Button { selectedFee = fee } label: {
                            HStack {
                                Image("partyGems")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 18, height: 18)
                                Text("\(fee)")
                                    .font(.system(size: 16, weight: .semibold))
                                Spacer()
                                Image(systemName: selectedFee == fee ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedFee == fee ? Theme.Palette.brandPink : .white.opacity(0.45))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 48)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedFee == fee ? Theme.Palette.brandPink.opacity(0.2) : Color.white.opacity(0.08))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(L10n.PartyRoom.superWheelRewardHint)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.78))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                guard let selectedFee else { return }
                Task { await wheelStore.open(roomId: roomId, entryFee: selectedFee) }
            } label: {
                Group {
                    if wheelStore.isPerformingAction {
                        ProgressView().tint(.white)
                    } else {
                        Text(L10n.PartyRoom.superWheelOpen).font(.system(size: 16, weight: .bold))
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Capsule().fill(selectedFee == nil || !wheelStore.isEnabled
                    ? Color.white.opacity(0.16)
                    : Theme.Palette.brandPink))
            }
            .buttonStyle(.plain)
            .disabled(selectedFee == nil || !wheelStore.isEnabled || wheelStore.isPerformingAction)
        }
        .padding(24)
        .task {
            await wheelStore.prepareConfig()
            if selectedFee == nil { selectedFee = wheelStore.entryFees.first }
        }
        .onChange(of: wheelStore.entryFees) { fees in
            if selectedFee == nil || !fees.contains(selectedFee ?? 0) {
                selectedFee = fees.first
            }
        }
        .onChange(of: wheelStore.isConfigPresented) { visible in
            if !visible { dismiss() }
        }
        .overlay {
            if showsRules {
                PartySuperWheelRulesOverlay { showsRules = false }
            }
        }
    }
}

/// 所有人可查看的转盘状态与操作面板。动画由服务端阶段广播推进；客户端不自行抽取结果。
struct PartySuperWheelPanel: View {
    @ObservedObject var wheelStore: PartySuperWheelStore
    let isRoomOwner: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var reportedFinalRoundID: String?
    @State private var showsRules = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 12) {
                header
                if let state = wheelStore.wheelState {
                    Text(L10n.PartyRoom.superWheelTitle)
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundColor(Color(hex: 0xFFDD63))
                        .padding(.top, 44)
                        .overlay(alignment: .top) {
                            if wheelStore.hasBigCountdown {
                                VStack(spacing: 2) {
                                    Text("\(wheelStore.remainingSeconds)")
                                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                                        .foregroundColor(Color(hex: 0xA8FC56))
                                        .monospacedDigit()
                                    if state.state == 4 {
                                        Text(L10n.PartyRoom.superWheelGetReady)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(Color(hex: 0xFFE9A6))
                                    }
                                }
                                .transition(.opacity)
                            }
                        }

                    PartySuperWheelDial(state: state)
                        .frame(height: 218)

                    HStack(spacing: 5) {
                        Image("partyGems")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                        Text("\(state.totalPool)")
                            .font(.system(size: 19, weight: .bold))
                        Text(L10n.PartyRoom.superWheelPool)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.62))
                    }
                    .foregroundColor(.white)

                    ScrollView(.horizontal, showsIndicators: false) {
                        participantGrid(state.participants)
                    }
                        .frame(height: 62)

                    actionBar.frame(height: 56)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: 360)
        }
        .overlay {
            if wheelStore.shouldPresentResult {
                PartySuperWheelResultOverlay(wheelStore: wheelStore, isRoomOwner: isRoomOwner)
            }
            if showsRules {
                PartySuperWheelRulesOverlay { showsRules = false }
            }
        }
        .task(id: finalResultTrackingKey) {
            reportFinalResultIfNeeded()
        }
    }

    private var header: some View {
        HStack {
            Button {
                if isRoomOwner, wheelStore.isActive {
                    Task { await wheelStore.close() }
                } else {
                    minimize()
                }
            } label: {
                Image(systemName: isRoomOwner && wheelStore.isActive ? "xmark.circle.fill" : "chevron.left.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))
            }
            .buttonStyle(.plain)

            Spacer()
            VStack(spacing: 2) {
                Text(statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.82))
                if wheelStore.remainingSeconds > 0, !wheelStore.hasBigCountdown {
                    Text("\(wheelStore.remainingSeconds)s")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: 0xFFDD63))
                        .monospacedDigit()
                }
            }
            Spacer()

            HStack(spacing: 14) {
                Button { showsRules = true } label: {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundColor(.white.opacity(0.88))
                }
                Button(action: minimize) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white.opacity(0.88))
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func minimize() {
        wheelStore.dismissPanel()
        dismiss()
    }

    private func participantGrid(_ participants: [PartySuperWheelParticipant]) -> some View {
        LazyHStack(spacing: 8) {
            ForEach(participants) { participant in
                VStack(spacing: 4) {
                    CachedAsyncImage(url: participant.avatar.flatMap(URL.init(string:)), contentMode: .fill, persistent: true) {
                        Circle().fill(Color.white.opacity(0.14))
                    }
                    .frame(width: 42, height: 42)
                    .clipShape(Circle())
                    .opacity(participant.status == 2 ? 0.35 : 1)
                    Text(participant.nickname ?? L10n.PartyRoom.superWheelPlayer)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(participant.status == 2 ? 0.4 : 0.85))
                        .lineLimit(1)
                }
                .frame(width: 46)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var actionBar: some View {
        Group {
            if wheelStore.shouldShowBetArea {
                HStack(spacing: 16) {
                    winningRatio
                    HStack(spacing: 8) {
                        betButton(50)
                        betButton(500)
                    }
                }
            } else if wheelStore.canJoin {
                Button { Task { await wheelStore.join() } } label: {
                    HStack(spacing: 6) {
                        Text(L10n.PartyRoom.superWheelJoin)
                        Text("· \(wheelStore.wheelState?.entryFee ?? 0)")
                        Image("partyGems").resizable().scaledToFit().frame(width: 18, height: 18)
                    }
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 184, height: 48)
                    .background(Capsule().fill(Theme.Palette.brandPink))
                }
                .buttonStyle(.plain)
                .disabled(wheelStore.isPerformingAction)
            } else if wheelStore.isMyParticipantAlive && wheelStore.isRegistering {
                actionButton(title: L10n.PartyRoom.superWheelJoined, disabled: true) {}
            } else if wheelStore.isSpectating {
                Text(L10n.PartyRoom.superWheelSpectating)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.68))
                    .frame(height: 48)
            } else {
                Color.clear.frame(height: 48)
            }
        }
    }

    private var winningRatio: some View {
        HStack(spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color(hex: 0x2E2E2E))
                    Capsule()
                        .fill(wheelStore.myWinningRatio >= 50 ? Color.red : Color(hex: 0xFF9D2C))
                        .frame(height: proxy.size.height * CGFloat(wheelStore.myWinningRatio) / 100)
                }
            }
            .frame(width: 11, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.PartyRoom.superWheelWinningRatio)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                Text("\(wheelStore.myWinningRatio)%")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(wheelStore.myWinningRatio >= 50 ? Color(hex: 0xF5AB00) : .white)
            }
        }
        .frame(width: 114, alignment: .leading)
    }

    private func betButton(_ amount: Int) -> some View {
        Button { Task { await wheelStore.bet(amount: amount) } } label: {
            HStack(spacing: 3) {
                Text("+\(amount)")
                Image("partyGems").resizable().scaledToFit().frame(width: 15, height: 15)
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 86, height: 48)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x9A3EF7)))
            .grayscale(wheelStore.isBetDisabled ? 1 : 0)
            .opacity(wheelStore.isBetDisabled ? 0.48 : 1)
        }
        .buttonStyle(.plain)
        .disabled(wheelStore.isBetDisabled || wheelStore.isPerformingAction)
    }

    private func actionButton(title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionButtonLabel(title: title) }
            .buttonStyle(.plain)
            .disabled(disabled || wheelStore.isPerformingAction)
    }

    private func actionButtonLabel(title: String) -> some View {
        Group {
            if wheelStore.isPerformingAction {
                ProgressView().tint(.white)
            } else {
                Text(title).font(.system(size: 16, weight: .bold))
            }
        }
        .foregroundColor(.white)
        .frame(width: 184, height: 48)
        .background(Capsule().fill(Theme.Palette.brandPink.opacity(0.48)))
    }

    private var statusText: String {
        switch wheelStore.wheelState?.state {
        case 1, 2: return L10n.PartyRoom.superWheelWaiting
        case 3: return L10n.PartyRoom.superWheelSignup
        case 4: return L10n.PartyRoom.superWheelPreparing
        case 5: return L10n.PartyRoom.superWheelBetting
        case 6: return L10n.PartyRoom.superWheelSpinning
        case 7: return L10n.PartyRoom.superWheelRoundResult
        case 8: return L10n.PartyRoom.superWheelFinalResult
        default: return ""
        }
    }

    private var finalResultTrackingKey: String {
        let state = wheelStore.wheelState
        return "\(state?.roundId ?? "")-\(state?.state ?? 0)"
    }

    private func reportFinalResultIfNeeded() {
        guard let state = wheelStore.wheelState,
              state.state == 8,
              reportedFinalRoundID != state.roundId else { return }
        reportedFinalRoundID = state.roundId
        var properties = PartyAnalytics.roomProperties(roomId: state.roomId, ownerId: state.hostId)
        properties["dia"] = state.entryFee
        PartyAnalytics.track("b_wheel_result_view", properties: properties)
    }
}

/// 转盘只依据服务端已同步的轮次和阶段播放视觉过渡，绝不在客户端推导淘汰或获胜结果。
private struct PartySuperWheelDial: View {
    let state: PartySuperWheelState
    @State private var rotation = 0.0
    @State private var frozenParticipants: [PartySuperWheelParticipant] = []

    private var visibleParticipants: [PartySuperWheelParticipant] {
        if (state.state == 6 || state.state == 7), !frozenParticipants.isEmpty {
            return frozenParticipants
        }
        return state.participants.filter { $0.status == 1 }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    AngularGradient(
                        colors: [Color(hex: 0xFBDE29), Color(hex: 0xF29DE8), Color(hex: 0xA2A8F4),
                                 Color(hex: 0xF8BA50), Color(hex: 0x83F0F7), Color(hex: 0xB26DF8),
                                 Color(hex: 0xF763DA), Color(hex: 0x8BF592), Color(hex: 0xFBDE29)],
                        center: .center
                    )
                )
                .overlay(Circle().stroke(Color.white.opacity(0.58), lineWidth: 3))

            ZStack {
                ForEach(Array(visibleParticipants.enumerated()), id: \.element.id) { index, participant in
                    participantAvatar(participant)
                        .overlay {
                            if state.state == 7, participant.userId == state.eliminatedUserId {
                                Circle().stroke(Color(hex: 0xF0625A), lineWidth: 3)
                                    .shadow(color: Color(hex: 0xF0625A), radius: 4)
                            }
                        }
                        .offset(participantOffset(index: index, count: visibleParticipants.count))
                }
            }
            .rotationEffect(.degrees(rotation))

            Circle()
                .fill(Color(hex: 0x301151))
                .frame(width: 70, height: 70)
                .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 1))
            VStack(spacing: 2) {
                Text("#\(max(1, state.roundNo))")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text(L10n.PartyRoom.superWheelTitle)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(.white)

            Image(systemName: "triangle.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Color(hex: 0xFFEE82))
                .rotationEffect(.degrees(180))
                .offset(y: -91)
        }
        .frame(width: 184, height: 184)
        .frame(maxWidth: .infinity)
        .onAppear(perform: updateForState)
        .onChange(of: state.roundId) { _ in resetForNewRound() }
        .onChange(of: state.roundNo) { _ in updateForState() }
        .onChange(of: state.state) { _ in updateForState() }
        .onChange(of: state.eliminatedUserId) { _ in updateForState() }
        .accessibilityLabel(L10n.PartyRoom.superWheelTitle)
    }

    private func participantAvatar(_ participant: PartySuperWheelParticipant) -> some View {
        CachedAsyncImage(url: participant.avatar.flatMap(URL.init(string:)), contentMode: .fill, persistent: true) {
            Circle().fill(Color.white.opacity(0.22))
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
        .opacity(participant.status == 2 ? 0.32 : 1)
    }

    private func participantOffset(index: Int, count: Int) -> CGSize {
        let step = 2 * Double.pi / Double(max(count, 1))
        let angle = Double(index) * step
        return CGSize(width: sin(angle) * 66, height: -cos(angle) * 66)
    }

    private func updateForState() {
        guard state.state == 6 else {
            if state.state != 7 {
                frozenParticipants = []
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    rotation = (rotation / 360).rounded() * 360
                }
            }
            return
        }
        if frozenParticipants.isEmpty {
            frozenParticipants = state.participants.filter { $0.status == 1 }
        }
        let participants = frozenParticipants
        guard !participants.isEmpty else { return }
        let index = participants.firstIndex(where: { $0.userId == state.eliminatedUserId })
            ?? state.sectorIndex
            ?? 0
        let normalizedIndex = ((index % participants.count) + participants.count) % participants.count
        let targetBase = -Double(normalizedIndex) * 360 / Double(participants.count)
        var target = targetBase
        while target <= rotation { target += 360 }
        withAnimation(.timingCurve(0.12, 0.6, 0.12, 1, duration: 6)) {
            rotation = target + 5 * 360
        }
    }

    private func resetForNewRound() {
        frozenParticipants = []
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            rotation = 0
        }
    }
}

/// H5 的淘汰/终局结算层。结果完全由 1153/1154 或 /state 下发，不从盘面推导。
struct PartySuperWheelResultOverlay: View {
    @ObservedObject var wheelStore: PartySuperWheelStore
    let isRoomOwner: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.42).ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Button(action: closeOrMinimize) {
                        Image(systemName: isRoomOwner && wheelStore.isActive ? "xmark.circle.fill" : "chevron.left.circle.fill")
                            .font(.system(size: 23, weight: .semibold))
                    }
                    Spacer()
                    Button(action: wheelStore.dismissResult) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 18, weight: .bold))
                    }
                }
                .foregroundColor(.white.opacity(0.9))
                .buttonStyle(.plain)

                resultContent
            }
            .padding(22)
            .frame(maxWidth: 330)
            .background(
                LinearGradient(
                    colors: [Color(hex: 0x3E1168), Color(hex: 0x160026)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .shadow(color: Color(hex: 0xFFDD63).opacity(0.22), radius: 18)
        }
        .zIndex(2_000)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private var resultContent: some View {
        if wheelStore.resultKind == .winner, let state = wheelStore.wheelState {
            VStack(spacing: 12) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundColor(Color(hex: 0xFFE9A6))
                winnerAvatar(state)
                Text(L10n.PartyRoom.superWheelTitle)
                    .font(.system(size: 23, weight: .heavy, design: .rounded))
                    .foregroundColor(Color(hex: 0xFFDD00))
                Text(state.winner?.nickname ?? L10n.PartyRoom.superWheelPlayer)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                HStack(spacing: 5) {
                    Text("+\(state.winnerAmount ?? 0)")
                    Image("partyGems").resizable().scaledToFit().frame(width: 26, height: 26)
                }
                .font(.system(size: 24, weight: .heavy))
                .foregroundColor(Color(hex: 0xFFFB00))
            }
        } else if let state = wheelStore.wheelState, let eliminated = state.revealUser {
            VStack(spacing: 13) {
                Text(L10n.PartyRoom.superWheelTitle)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundColor(Color(hex: 0xFFDD63))
                Text(String(format: L10n.PartyRoom.superWheelOutFormat,
                            eliminated.nickname ?? L10n.PartyRoom.superWheelPlayer))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                userAvatar(eliminated, size: 106)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "cloud.rain.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(Color(hex: 0x93C5FD))
                            .offset(x: 6, y: 5)
                    }
                Text(L10n.PartyRoom.superWheelNextRound)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func winnerAvatar(_ state: PartySuperWheelState) -> some View {
        userAvatar(state.winner ?? PartySuperWheelUser(
            userId: state.winnerId ?? "",
            nickname: nil,
            avatar: nil
        ), size: 110)
            .overlay(Circle().stroke(Color(hex: 0xFFE9A6), lineWidth: 3))
    }

    private func userAvatar(_ user: PartySuperWheelUser, size: CGFloat) -> some View {
        CachedAsyncImage(url: user.avatar.flatMap(URL.init(string:)), contentMode: .fill, persistent: true) {
            Circle().fill(Color.white.opacity(0.16))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private func closeOrMinimize() {
        if isRoomOwner, wheelStore.isActive {
            Task { await wheelStore.close() }
        } else {
            wheelStore.dismissResult()
        }
    }
}

/// H5 规则正文刻意只维护英文，产品规则变更随客户端版本发布。
private struct PartySuperWheelRulesOverlay: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.58).ignoresSafeArea()
            VStack(spacing: 14) {
                HStack {
                    Spacer()
                    Text("Rules")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ruleSection(
                            1,
                            title: "Game Description",
                            text: "Super Winner is a multiplayer game started by room owners. Players join by paying an entry fee. The game starts automatically when more than two players join before the countdown ends."
                        )
                        Divider().overlay(Color.white.opacity(0.14))
                        ruleSection(
                            2,
                            title: "Game rewards",
                            text: "One player is eliminated each round until one winner remains. The winner receives 80% of the jackpot and the room owner receives 10%. If the game is closed before a winner is produced, all entry fees are refunded."
                        )
                        Divider().overlay(Color.white.opacity(0.14))
                        ruleSection(
                            3,
                            title: "Bets adding session",
                            text: "Each round has 5 seconds to add bets. Adding more bets during this period increases your winning probability."
                        )
                        Divider().overlay(Color.white.opacity(0.14))
                        Text("This game is not related to Apple.")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(14)
                    .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                }
                Button(L10n.Party.ok, action: onDismiss)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.Palette.brandPink, in: Capsule())
                    .buttonStyle(.plain)
            }
            .padding(20)
            .frame(maxWidth: 330, maxHeight: 560)
            .background(Color(hex: 0x1A0033), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 24)
        }
        .zIndex(2_100)
        .accessibilityAddTraits(.isModal)
    }

    private func ruleSection(_ index: Int, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(index). \(title)")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Color(hex: 0xFFB100))
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PartySuperWheelFloatingButton: View {
    let state: Int
    let onTap: () -> Void
    let onVisible: () -> Void
    @State private var isRotating = false

    private var showsWaiting: Bool { (1...5).contains(state) }
    private var isGameSpinning: Bool { (4...8).contains(state) }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottom) {
                Image(systemName: "circle.dotted.circle")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Color(hex: 0xFFDD63))
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color(hex: 0x4C286E).opacity(0.94)))
                    .overlay(Circle().stroke(Color(hex: 0xFFDD63).opacity(0.55), lineWidth: 1))
                    .rotationEffect(.degrees(isRotating ? 360 : 0))
                if showsWaiting {
                    Text(L10n.PartyRoom.superWheelWaiting)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(hex: 0xAD48FF)))
                        .offset(y: 5)
                }
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            onVisible()
            isRotating = isGameSpinning
        }
        .onChange(of: isGameSpinning) { spinning in
            isRotating = spinning
        }
        .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: isRotating)
        .accessibilityLabel(L10n.PartyRoom.superWheelTitle)
    }
}
