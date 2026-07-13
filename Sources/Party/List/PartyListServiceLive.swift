import Foundation

/// PartyListService 的生产实现——包装 `PartyAPI.roomList`。
///
/// 依赖 `PartyAPI`（间接依赖 `PartyAPIClient` / 网络 / crypto）——**不进 HilyTests 白名单**。
/// 单测走 `PartyListServicePreviewFake` 或 `FakePartyListService`。
///
/// **languageCode 传值**（spec §3 F-14）：调用方（PartyListStore）从 `AppLocaleStore.shared.currentLocale.identifier`
/// 取，避免三语用户看到错语言 rooms。
///
/// **snapshotId 不传**（spec §3 F-03）：现契约撕掉 envelope 拿不到分页级 sid，MVP 用 offset 分页足够。
struct PartyListServiceLive: PartyListService {
    func fetchList(
        kind: PartyRoomListKind,
        languageCode: String?,
        offset: Int?,
        pageSize: Int,
        queryParam: String?,
        version: String
    ) async throws -> [PartyRoomInfo] {
        try await PartyAPI.roomList(
            kind: kind,
            languageCode: languageCode,
            snapshotId: nil,
            offset: offset,
            pageSize: pageSize,
            queryParam: queryParam,
            version: version
        )
    }
}
