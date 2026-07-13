import Foundation

/// 派对房管管理状态机（房主设置页 Admin 子页）。
///
/// 对齐 H5 create.vue 编辑态 `partyAdminPopup`。
///
/// **操作策略**：
/// - fetch 列表 → 展示
/// - setAdmin：乐观 append 到列表；失败回退
/// - removeAdmin：乐观 remove；失败回滚
@MainActor
final class PartyAdminStore: ObservableObject {
    @Published private(set) var admins: [PartyRoomAdmin] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isMutating: Bool = false
    @Published private(set) var errorMessage: String = ""

    let roomId: String
    private let service: PartyAdminService

    init(roomId: String, service: PartyAdminService = PartyAdminServiceLive()) {
        self.roomId = roomId
        self.service = service
    }

    func loadInitial() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = ""
        defer { isLoading = false }
        do {
            admins = try await service.fetchAdminList(roomId: roomId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 添加一个新房管（userId 由 View 层通过输入或选人 sheet 提供）
    func addAdmin(userId: String, nickname: String? = nil, icon: String? = nil) async {
        guard !isMutating else { return }
        guard !admins.contains(where: { $0.userId == userId }) else { return }
        isMutating = true
        errorMessage = ""
        defer { isMutating = false }
        // 乐观 append
        let optimistic = PartyRoomAdmin(userId: userId, nickname: nickname, icon: icon)
        admins.append(optimistic)
        do {
            try await service.setAdmin(roomId: roomId, userId: userId)
            // 服务端成功后刷新列表拿真数据（含 nickname/icon）
            if let list = try? await service.fetchAdminList(roomId: roomId) {
                admins = list
            }
        } catch {
            // 回滚
            admins.removeAll { $0.userId == userId }
            errorMessage = error.localizedDescription
        }
    }

    func removeAdmin(_ admin: PartyRoomAdmin) async {
        guard !isMutating else { return }
        isMutating = true
        errorMessage = ""
        defer { isMutating = false }
        let index = admins.firstIndex(of: admin)
        // 乐观 remove
        admins.removeAll { $0.userId == admin.userId }
        do {
            try await service.removeAdmin(roomId: roomId, userId: admin.userId)
        } catch {
            // 回滚
            if let i = index, i <= admins.count {
                admins.insert(admin, at: i)
            } else {
                admins.append(admin)
            }
            errorMessage = error.localizedDescription
        }
    }

    func clearError() { errorMessage = "" }
}
