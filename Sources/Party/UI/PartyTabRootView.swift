import SwiftUI

/// 派对房主 tab 根容器（E-spec §0.2）。
///
/// **职责**：
/// - 承载 `NavigationStack(path: $partyPath)` + `PartyListStore` 生命周期
/// - 挂 `.navigationDestination(for: PartyRoute.self)` 分发 create/room 子页
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
    /// language provider 从 `AppLocaleStore.shared.currentLocale.identifier` 取（E-spec §3 F-14）。
    @StateObject private var listStore = PartyListStore(
        service: PartyListServiceLive(),
        pageSize: PartyListStore.defaultPageSize,
        languageCodeProvider: {
            let raw = AppLocaleStore.shared.current.rawValue
            return raw.isEmpty ? nil : raw
        }
    )

    var body: some View {
        NavigationStack(path: $path) {
            PartyRoomListView(
                store: listStore,
                onTapCreate: { path.append(PartyRoute.create) },
                onTapCrown: {
                    // MVP：仅显图标，业务不做（E-spec §0.3 crown 保留占位）
                },
                onTapRoom: { roomId in
                    path.append(PartyRoute.room(id: roomId, password: nil))
                }
            )
            .navigationDestination(for: PartyRoute.self) { route in
                switch route {
                case .create:
                    PartyCreateRoomView()
                case .room(let id, _):
                    PartyRoomView(roomId: id)
                }
            }
        }
    }
}
