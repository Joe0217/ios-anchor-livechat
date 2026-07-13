import Foundation

/// 派对房 3 tab store（Party/Follow/Recent）共用契约。
/// State 复用 `PartyListStore.State`（refactor 后 6 态适合空态占位 store 落 `.loaded(rooms: [], hasMore: false)`）。
///
/// PartyRoomListContent view 泛型消费本 protocol，一处 UI 实现覆盖 3 个 tab。
@MainActor
protocol PartyRoomListLike: ObservableObject {
    var state: PartyListStore.State { get }
    func startInitial()
    func refreshAsync() async
    func loadMore()
    func retry()
    func retryPage()
}

extension PartyListStore: PartyRoomListLike {}
