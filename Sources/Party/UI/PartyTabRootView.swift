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

    // v8：密码房前置弹窗（对齐 H5 index.vue L178-182 语义）
    /// 点击密码房时待确认的房间 id（非空时弹密码 alert）
    @State private var pendingPasswordRoomId: String? = nil
    /// 密码 alert 用户输入
    @State private var enteredPassword: String = ""

    var body: some View {
        NavigationStack(path: $path) {
            PartyListMainView(
                listStore: listStore,
                onTapCreate: tapCreate,
                onTapMyRoom: { roomId in
                    // v2：已有 myRoom 时点击浮动按钮直接进自己的房（对齐 H5 index.vue L191-207）
                    path.append(PartyRoute.room(id: roomId, password: nil))
                },
                onTapRoom: { room in
                    handleTapRoom(room)
                },
                onTapSearch: { path.append(PartyRoute.search) }
            )
            .navigationDestination(for: PartyRoute.self) { route in
                switch route {
                case .create:
                    // v7 对齐安卓：注入 defaultName / defaultAvatarUrl（登录头像）+ userLevel
                    // 提交成功后 replace path 到 PartyRoomView（不留 create 页在栈上）
                    PartyCreateRoomView(
                        defaultName: makeDefaultRoomName(),
                        defaultAvatarUrl: makeDefaultAvatarUrl(),
                        userLevel: AnchorInfoStore.shared.mine?.level ?? 0,
                        onCreated: { roomId in
                            path.removeLast()
                            path.append(PartyRoute.room(id: roomId, password: nil))
                            // v2：刚创建完房 pop 回大厅时刷新 myRoom 状态，浮按钮切到 My Room
                            Task { await listStore.reloadMyRoom() }
                        }
                    )
                case .room(let id, let password):
                    PartyRoomView(roomId: id, password: password)
                case .search:
                    PartySearchView(onTapRoom: { room in
                        handleTapRoom(room)
                    })
                }
            }
        }
        // v8：密码房前置 alert（对齐 H5 index.vue L178-182 语义）
        // isPresented 由 pendingPasswordRoomId 非 nil 派生；SecureField 承载输入
        .alert(
            L10n.Party.passwordAlertTitle,
            isPresented: Binding(
                get: { pendingPasswordRoomId != nil },
                set: { if !$0 { pendingPasswordRoomId = nil; enteredPassword = "" } }
            ),
            presenting: pendingPasswordRoomId
        ) { roomId in
            SecureField(L10n.Party.passwordPlaceholder, text: $enteredPassword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(L10n.Party.passwordConfirm) {
                let pwd = enteredPassword.trimmingCharacters(in: .whitespaces)
                pendingPasswordRoomId = nil
                enteredPassword = ""
                path.append(PartyRoute.room(id: roomId, password: pwd.isEmpty ? nil : pwd))
            }
            Button(L10n.Party.passwordCancel, role: .cancel) {
                pendingPasswordRoomId = nil
                enteredPassword = ""
            }
        } message: { _ in
            Text(L10n.Party.passwordAlertMessage)
        }
        .overlay(alignment: .top) {
            if let t = permissionDeniedToast {
                Text(t)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [
                                    Theme.Palette.partyCreateBtnA.opacity(0.4),
                                    Theme.Palette.partyCreateBtnB.opacity(0.4)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    )
                    .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    .padding(.top, 60)
                    .transition(.opacity)
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        permissionDeniedToast = nil
                    }
            }
        }
    }

    // MARK: - Actions

    /// v8：房卡点击统一入口（PartyListMainView + PartySearchView 共用）。
    /// 密码房 → 弹密码 alert，输入密码后再 push；普通房 → 直接 push。
    /// 对齐 H5 index.vue L165-188 `clickRoomItem` 密码房判断（H5 那段已注释，iOS 按语义激活）。
    private func handleTapRoom(_ room: PartyRoomInfo) {
        guard let rid = room.id, !rid.isEmpty else { return }
        let isLocked = (room.lockFlag == 1) || (room.needPassword == true)
        if isLocked {
            enteredPassword = ""
            pendingPasswordRoomId = rid
        } else {
            path.append(PartyRoute.room(id: rid, password: nil))
        }
    }

    private func tapCreate() {
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
