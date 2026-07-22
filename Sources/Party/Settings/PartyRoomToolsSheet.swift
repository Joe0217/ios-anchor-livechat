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
    /// 房主资产账户：宝石兑换钻石或金币。
    case currencyExchange
    var id: String { rawValue }
}

/// 派对房「Room Tools」sheet — 房主/房管 tap 顶栏齿轮时弹起。
///
/// **对齐 H5 用户端** `livechat-h5/src/components/party/components/room-mana-popup.vue`：
/// - 底部 sheet + 3 列网格 + 顶部居中标题 "Room Tools"
/// - 各项按 role 显示（Owner-only 项：Lock Room / Room Mode / MC Seat / Settings；Owner + PlatformAdmin：MC Seat；全部房管：Music / Mic Application / Blocklist）
/// - Settings 已从"全部房管"降到 Owner-only（对齐文档 A §1"修改房间信息/背景/公告 · 仅房主"）
/// - iOS MVP：Settings/Blocklist tap 触发导航；其余项 stub log（真机可见项以定位后端 wiring 完成度）
///
/// 用 enum-driven 单 sheet 切换（tools ↔ settings）避免 iOS 16 双 sheet race。
struct PartyRoomToolsSheet: View {
    /// 房主 or 平台管理员判定（决定 Owner-only 项可见）
    let isOwner: Bool
    /// 收益资产是账号私有资源，必须是当前房间真实房主，不能复用平台管理员提权后的 `isOwner`。
    let isSelfRoomOwner: Bool
    /// 平台管理员（非房主）判定（MC Seat 也允许）
    let isPlatformAdmin: Bool
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
    /// 房币入口仅归真实房主，避免房管误操作个人资产账户。
    let onTapCurrencyExchange: () -> Void
    /// 其他 stub 项 tap 通用回调（View 可 toast "Coming soon"）
    let onTapStub: (String) -> Void

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
                            onTapLockRoom()
                        }
                    }
                    if isMusicAvailable {
                        toolItem(
                            icon: "music.note",
                            label: L10n.Party.toolMusic,
                            isOn: isMusicEnabled
                        ) {
                            onTapMusic()
                        }
                    }
                    // Settings 仅房主可见（对齐文档 A §1"修改房间信息/背景/公告 · 仅房主"；房管禁止改房间信息）
                    // android 亦通过入口 gate（PartyRoomSettingActivity.kt），非在 view 内自持角色
                    if isOwner {
                        toolItem(icon: "gearshape.fill", label: L10n.Party.toolSettings, isPrimary: true) {
                            onTapSettings()
                        }
                    }
                    // H5 关闭态仍显示该入口，并以 OFF 告知房主可直接开启。
                    toolItem(
                        icon: isMicApplicationOn ? "hand.raised.fill" : "hand.raised.slash.fill",
                        label: L10n.Party.toolMicApplication,
                        isOn: isMicApplicationOn
                    ) {
                        onTapMicApplication()
                    }
                    if isOwner {
                        toolItem(icon: "square.grid.2x2.fill", label: L10n.Party.toolRoomMode) {
                            onTapRoomMode()
                        }
                    }
                    toolItem(icon: "person.crop.circle.badge.minus", label: L10n.Party.toolBlocklist) {
                        onTapBlocklist()
                    }
                    if isOwner || isPlatformAdmin {
                        toolItem(
                            icon: isMCSeatEnabled ? "mic.fill" : "mic.slash.fill",
                            label: L10n.Party.toolMCSeat,
                            isOn: isMCSeatEnabled
                        ) {
                            onTapMCSeat()
                        }
                    }
                    if isSelfRoomOwner {
                        toolItem(icon: "arrow.left.arrow.right.circle.fill", label: L10n.Party.toolCurrencyExchange) {
                            onTapCurrencyExchange()
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

    func generate(roomId: String) async -> Bool {
        guard !roomId.isEmpty, !isGenerating else { return false }
        isGenerating = true
        defer { isGenerating = false }
        do {
            return try await PartyAPI.generateLuckyNumber(roomId: roomId)
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
    let showPk: Bool
    let isRoomMuted: Bool
    let onStartPk: () -> Void
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
                        guard await luckyNumberStore.generate(roomId: roomId) else { return }
                        dismiss()
                        AppToastCenter.shared.show(L10n.PartyRoom.toolMenuLuckyNumberSent)
                    }
                } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            // 与 H5 party-tool-menu.vue 使用同一张 50px Lucky Number 图标。
                            CachedAsyncImage(
                                url: URL(string: "https://file.lovetravel.link/mstatic/lucky-num/lucky-num-icon.webp"),
                                contentMode: .fit
                            ) {
                                Circle()
                                    .fill(LinearGradient(
                                        colors: [Color(red: 1.0, green: 0.72, blue: 0.12), Color(red: 1.0, green: 0.28, blue: 0.42)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                                    .overlay(
                                        Text("7")
                                            .font(.system(size: 30, weight: .black, design: .rounded))
                                            .foregroundColor(.white)
                                    )
                            }
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
            VStack(spacing: 0) {
                CachedAsyncImage(
                    url: URL(string: "https://img.hnhily.link/mstatic/party/party-color-none.webp"),
                    contentMode: .fit,
                    persistent: true
                ) {
                    Image("EmptyStatePlaceholder")
                        .resizable()
                        .scaledToFit()
                }
                .frame(width: 160, height: 160)
                .padding(.bottom, 20)

                Text(L10n.PartyRoom.toolMenuNoHistory)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
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
                    CachedAsyncImage(
                        url: URL(string: "https://file.lovetravel.link/mstatic/lucky-num/winning-img.webp"),
                        contentMode: .fit
                    ) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 42, weight: .bold))
                            .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.24))
                            .frame(width: 288, height: 130)
                    }
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
