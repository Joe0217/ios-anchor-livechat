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

    var body: some View {
        NavigationStack(path: $path) {
            PartyListMainView(
                listStore: listStore,
                onTapCreate: tapCreate,
                onTapRoom: { roomId in
                    path.append(PartyRoute.room(id: roomId, password: nil))
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
                        }
                    )
                case .room(let id, _):
                    PartyRoomView(roomId: id)
                case .search:
                    PartySearchView(onTapRoom: { roomId in
                        path.append(PartyRoute.room(id: roomId, password: nil))
                    })
                }
            }
        }
        .overlay(alignment: .top) {
            if let t = permissionDeniedToast {
                Text(t)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
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

    private func tapCreate() {
        guard !checkingPermission else { return }
        checkingPermission = true
        Task {
            defer { Task { @MainActor in checkingPermission = false } }
            do {
                let cond = try await createService.fetchCreateConditions()
                await MainActor.run {
                    if cond.canCreateRoom {
                        path.append(PartyRoute.create)
                    } else {
                        permissionDeniedToast = L10n.Party.createPermissionDenied
                    }
                }
            } catch {
                // 网络错保守 fallback：直接 push（对齐安卓宽松策略；无网络不阻塞 UI）
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
