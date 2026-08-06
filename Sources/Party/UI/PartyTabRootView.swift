import SwiftUI

/// 派对房主 tab 根容器（E-spec §0.2）。
///
/// **职责**：
/// - 承载 `NavigationStack(path: $partyPath)` + `PartyListStore` 生命周期
/// - 挂 `.navigationDestination(for: PartyRoute.self)` 分发 create/room 子页
/// - v7 对齐安卓：tap Create 前置 `getCreateRoomConditions` 权限 gate；失败弹 toast 不 push
///
/// **归属决策**（E-spec §6B）：
/// - `PartyListStore` = view-owned `@StateObject`（tab 销毁重建策略下随 view 一起 deinit + cancel task）
/// - `partyPath` = 外部注入（由 `MainTabView` 持有），子页 push 时 tabbar 用 `isSubpagePushed` 自然隐藏
///
/// **登出清理**：不需要 store 显式 reset —— 用户登出 → `RootView` 切 LoginView → MainTabView dismount →
/// PartyTabRootView dismount → PartyListStore deinit → currentTask cancel（自动路径）。
struct PartyTabRootView: View {
    @Binding var path: NavigationPath
    @ObservedObject private var permission = SelfPermissionBridge.shared

    /// view-owned Store。构造时注入 Live service。
    @StateObject private var listStore = PartyListStore(
        service: PartyListServiceLive(),
        pageSize: PartyListStore.defaultPageSize,
        languageCodeProvider: {
            let raw = AppLocaleStore.shared.current.rawValue
            return raw.isEmpty ? nil : raw
        }
    )

    /// 创房权限 gate 检查（v7 对齐安卓 PartyFragment.getCreatePartyRoomConditions）
    private let createService: PartyCreateService = PartyCreateServiceLive()
    @State private var permissionDeniedToast: String? = nil
    @State private var checkingPermission = false

    // 密码房前置 sheet：H5 限制 4 位数字，校验接口成功后才创建房间路由。
    @State private var pendingPasswordRoom: PasswordRoom?
    @State private var autoEnteringPasswordRoomID: String?

    private var canShowValueRankings: Bool {
        permission.canVirtualItems && permission.canGiftSending
    }

    private var bypassesCreateRoomPermissionCheck: Bool {
        isPartyOnlyMode
    }

    private var isPartyOnlyMode: Bool {
        let effectiveUserType = permission.effectiveUserTypeSnapshot
            ?? UserTypeExperience.effectiveUserType(isAuthenticated: SessionStore.shared.isLoggedIn)
        return UserTypeExperience.isPartyOnly(effectiveUserType)
    }

    var body: some View {
        NavigationStack(path: $path) {
            PartyListMainView(
                listStore: listStore,
                isLobbyVisible: path.isEmpty,
                onTapCreate: tapCreate,
                onTapMyRoom: { roomId, entryPath in
                    // v2：已有 myRoom 时点击浮动按钮直接进自己的房（对齐 H5 index.vue L191-207）
                    path.append(PartyRoute.room(id: roomId, password: nil, entryPath: entryPath))
                },
                onTapRoom: { room, entryPath in
                    handleTapRoom(room, entryPath: entryPath)
                },
                onTapSearch: { path.append(PartyRoute.search) },
                onTapRanking: {
                    guard SelfPermissionBridge.shared.gate(.virtualItems, action: "partyLobbyRanking"),
                          SelfPermissionBridge.shared.gate(.giftSending, action: "partyLobbyRanking") else {
                        return
                    }
                    path.append(PartyRoute.lobbyRanking(.partyRich))
                },
                onTapBannerRoom: { roomId, entryPath in
                    path.append(PartyRoute.room(id: roomId, password: nil, entryPath: entryPath))
                },
                onEnterTopRoomGuide: { guide, topRankLimit in
                    enterTopRoomGuide(guide, topRankLimit: topRankLimit)
                }
            )
            .navigationDestination(for: PartyRoute.self) { route in
                switch route {
                case .create:
                    // v7 对齐安卓：注入 defaultName / defaultAvatarUrl（登录头像）+ userLevel
                    // 提交成功后 replace path 到 PartyRoomView（不留 create 页在栈上）
                    PartyCreateRoomView(
                        defaultName: makeDefaultRoomName(),
                        defaultTagline: isPartyOnlyMode
                            ? "Let's chat and have fun."
                            : "Let's chat and have fun together.",
                        defaultAvatarUrl: makeDefaultAvatarUrl(),
                        userLevel: AnchorInfoStore.shared.mine?.level ?? 0,
                        taglineLengthLimit: isPartyOnlyMode ? 24 : PartyCreateStore.maxTaglineLength,
                        onCreated: { roomId in
                            path.removeLast()
                            path.append(PartyRoute.room(id: roomId, password: nil, entryPath: .myRoom))
                            // v2：刚创建完房 pop 回大厅时刷新 myRoom 状态，浮按钮切到 My Room
                            Task { await listStore.reloadMyRoom() }
                        }
                    )
                case let .room(id, password, entryPath):
                    PartyRoomView(roomId: id, password: password, entryPath: entryPath) { guide in
                        if !path.isEmpty { path.removeLast() }
                        enterTopRoomGuide(
                            guide,
                            topRankLimit: PartyHotRoomTaskStore.shared.topRankLimit
                        )
                    }
                case .search:
                    PartySearchView(onTapRoom: { room in
                        handleTapRoom(room, entryPath: .search)
                    })
                case .lobbyRanking(let kind):
                    if canShowValueRankings {
                        PartyLobbyRankingView(initialKind: kind) { roomId in
                            path.append(PartyRoute.room(id: roomId, password: nil, entryPath: .rankRoom))
                        }
                    } else {
                        EmptyView()
                    }
                }
            }
            // Party 大厅右上角榜单与首页复用同一目的地，避免维护两套榜单页面。
            .navigationDestination(for: HomeLeaderboardRoute.self) { route in
                switch route {
                case .ranking:
                    HomeRankingView()
                case .points:
                    PointsRankView()
                }
            }
        }
        .sheet(item: $pendingPasswordRoom) { room in
            PartyEnterPasswordSheet(roomId: room.id, store: PartyStore.shared) {
                pendingPasswordRoom = nil
                path.append(PartyRoute.room(id: room.id, password: nil, entryPath: room.entryPath))
            }
            .giftPanelSheetBackground()
        }
        .overlay(alignment: .top) {
            if let t = permissionDeniedToast {
                Text(t)
                    .toastStyle()
                    .transition(Toast.transition)
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: Toast.dismissDurationNanos)
                        permissionDeniedToast = nil
                    }
            }
        }
    }

    // MARK: - Actions

    /// v8：房卡点击统一入口（PartyListMainView + PartySearchView 共用）。
    /// 密码房 → 弹密码 alert，输入密码后再 push；普通房 → 直接 push。
    /// 对齐 H5 index.vue L165-188 `clickRoomItem` 密码房判断（H5 那段已注释，iOS 按语义激活）。
    private func handleTapRoom(_ room: PartyRoomInfo, entryPath: PartyRoomEntryPath) {
        // P 项目权限管理：走统一 gate helper（code-review Finding 6 消除 4 行复制）
        guard SelfPermissionBridge.shared.gate(.party, action: "handleTapRoom") else { return }
        // F 期 Live↔Party 互斥（对齐安卓 isLiveing||isPartying toast，2026-07-17）：
        // 直播活跃态禁止进派对房；LiveRoomView 用 @StateObject 独立实例但其他组件（AvatarView / UserCardStore）
        // 已把 LiveStore.shared 作为权威源，此处沿用
        if LiveStore.shared.state == .living {
            permissionDeniedToast = L10n.Party.mutexBlockedByLive
            return
        }
        guard let rid = room.id, !rid.isEmpty else { return }
        let isLocked = (room.lockFlag == 1) || (room.needPassword == true)
        if isLocked {
            enterPasswordProtectedRoom(id: rid, entryPath: entryPath)
        } else {
            path.append(PartyRoute.room(id: rid, password: nil, entryPath: entryPath))
        }
    }

    /// Top 房引导不能直接按接口返回的单个 roomId 进房：该房可能已加密码。
    /// 先从 TopX 列表挑选非密码房；只有全部加密时才落到密码输入校验流程。
    private func enterTopRoomGuide(_ guide: PartyHotRoomGuide, topRankLimit: Int) {
        guard SelfPermissionBridge.shared.gate(.party, action: "enterTopRoomGuide"),
              SelfPermissionBridge.shared.gate(.partyActivities, action: "enterTopRoomGuide") else { return }
        if LiveStore.shared.state == .living {
            permissionDeniedToast = L10n.Party.mutexBlockedByLive
            return
        }
        guard !guide.roomId.isEmpty else { return }

        Task {
            guard let target = await preferredTopRoomTarget(guide, topRankLimit: topRankLimit) else {
                permissionDeniedToast = L10n.Party.errorNetworkLost
                return
            }
            guard LiveStore.shared.state != .living else {
                permissionDeniedToast = L10n.Party.mutexBlockedByLive
                return
            }
            if target.requiresPassword {
                enterPasswordProtectedRoom(id: target.roomId, entryPath: .topRoomGuide)
            } else {
                path.append(PartyRoute.room(id: target.roomId, password: nil, entryPath: .topRoomGuide))
            }
        }
    }

    private func preferredTopRoomTarget(
        _ guide: PartyHotRoomGuide,
        topRankLimit: Int
    ) async -> TopRoomEntryTarget? {
        let rankLimit = max(1, topRankLimit)
        do {
            let rooms = try await PartyAPI.roomList(pageSize: max(20, rankLimit))
            let rankedCandidates = rooms
                .filter { room in
                    guard let roomId = room.id, !roomId.isEmpty, room.roomStatus != 2,
                          let rank = room.rangIndex else {
                        return false
                    }
                    return (1...rankLimit).contains(rank)
                }
                .sorted { ($0.rangIndex ?? .max) < ($1.rangIndex ?? .max) }
            // 少数列表回包没有 rangIndex 时，至少使用 availableSeat 接口指定的房间完成密码预检。
            let candidates = rankedCandidates.isEmpty
                ? rooms.filter { $0.id == guide.roomId && $0.roomStatus != 2 }
                : rankedCandidates

            if let selected = candidates.first(where: { !Self.isPasswordProtected($0) })
                ?? candidates.first {
                guard let roomId = selected.id else { return nil }
                return TopRoomEntryTarget(roomId: roomId, requiresPassword: Self.isPasswordProtected(selected))
            }
        } catch {
            AppLogger.party.notice("[PartyTopRoomGuide] top room password preflight failed: \(String(describing: error), privacy: .public)")
        }

        // 列表暂时未包含 TopX 时，仅在 availableSeat 接口明确下发锁房状态后才使用其目标；
        // 未知状态绝不直接进入，避免密码错误后才被强制退回大厅。
        guard let isPasswordProtected = guide.isPasswordProtected else { return nil }
        return TopRoomEntryTarget(roomId: guide.roomId, requiresPassword: isPasswordProtected)
    }

    private static func isPasswordProtected(_ room: PartyRoomInfo) -> Bool {
        room.lockFlag == 1 || room.needPassword == true
    }

    private func enterPasswordProtectedRoom(id: String, entryPath: PartyRoomEntryPath) {
        guard isPartyOnlyMode else {
            pendingPasswordRoom = PasswordRoom(id: id, entryPath: entryPath)
            return
        }
        guard autoEnteringPasswordRoomID == nil else { return }
        autoEnteringPasswordRoomID = id
        Task { @MainActor in
            let error = await PartyStore.shared.validateRoomEntryPassword(roomId: id, password: "0000")
            autoEnteringPasswordRoomID = nil
            guard error == nil else {
                pendingPasswordRoom = PasswordRoom(id: id, entryPath: entryPath)
                return
            }
            path.append(PartyRoute.room(id: id, password: nil, entryPath: entryPath))
        }
    }

    private struct PasswordRoom: Identifiable {
        let id: String
        let entryPath: PartyRoomEntryPath
    }

    private struct TopRoomEntryTarget {
        let roomId: String
        let requiresPassword: Bool
    }

    private func tapCreate() {
        // P 项目权限管理：走统一 gate helper（code-review Finding 6 消除 4 行复制）
        guard SelfPermissionBridge.shared.gate(.party, action: "tapCreate") else { return }
        // F 期 Live↔Party 互斥：直播中禁止创房（同 handleTapRoom 语义）
        if LiveStore.shared.state == .living {
            permissionDeniedToast = L10n.Party.mutexBlockedByLive
            return
        }
        // 107 使用审核专用创房接口，服务端不要求通用创房资格预检。
        guard !bypassesCreateRoomPermissionCheck else {
            AppLogger.party.info("[PartyTab] 107 bypass create-room permission check")
            path.append(PartyRoute.create)
            return
        }
        AppLogger.party.info("[PartyTab] tapCreate begin checking=\(self.checkingPermission, privacy: .public)")
        guard !checkingPermission else { return }
        checkingPermission = true
        Task {
            defer { Task { @MainActor in checkingPermission = false } }
            do {
                let cond = try await createService.fetchCreateConditions()
                AppLogger.party.info("[PartyTab] cond canCreate=\(cond.canCreateRoom, privacy: .public) lv=\(cond.createRoomLevel ?? -1, privacy: .public)")
                await MainActor.run {
                    if cond.canCreateRoom {
                        AppLogger.party.info("[PartyTab] push .create")
                        path.append(PartyRoute.create)
                    } else {
                        AppLogger.party.info("[PartyTab] toast permissionDenied")
                        permissionDeniedToast = L10n.Party.createPermissionDenied
                    }
                }
            } catch {
                // 网络错保守 fallback：直接 push（对齐安卓宽松策略；无网络不阻塞 UI）
                AppLogger.party.error("[PartyTab] fetchCreateConditions failed: \(String(describing: error), privacy: .public); fallback push")
                await MainActor.run { path.append(PartyRoute.create) }
            }
        }
    }

    // MARK: - Defaults

    /// 默认房名 `{nickname}'s Room`（对齐 H5 create.vue:42 与安卓预填）
    private func makeDefaultRoomName() -> String {
        let nick = AnchorInfoStore.shared.mine?.nickname
                ?? SessionStore.shared.user?.nickname
                ?? ""
        let trimmed = nick.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "" : "\(trimmed)'s Room"
    }

    /// 默认头像 URL（对齐 H5 userStore.mineInfo.icon 与安卓预填登录头像）
    private func makeDefaultAvatarUrl() -> String? {
        AnchorInfoStore.shared.mine?.icon ?? SessionStore.shared.user?.icon
    }
}
