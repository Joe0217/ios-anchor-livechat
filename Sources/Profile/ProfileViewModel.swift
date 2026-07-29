import Foundation
import SwiftUI
import Combine

/// Profile 屏 UI 状态包装（selectedTab）+ 转发 `AnchorInfoStore` 数据派生。
///
/// 主播信息持久层在 `AnchorInfoStore.shared`（singleton）；本 ViewModel 仅:
/// - 持有 selectedTab（tab 切换是 UI-only 状态，不需要持久化）
/// - 通过 cancellable 中继 store 的 objectWillChange，让 View 用 `vm.xxx` 读时仍能触发刷新
/// - 暴露字段透传到 store（保持子视图签名不变，便于增量重构）
@MainActor
final class ProfileViewModel: ObservableObject {

    /// LoadState 类型透传（view 端继续用 `vm.LoadState` switch；底层是 store 的同类型）
    typealias LoadState = AnchorInfoStore.LoadState

    let store: AnchorInfoStore = .shared

    /// 内容 tab 选项（UI-only，view 端独占）
    @Published var selectedTab: ProfileTab = .album

    private var cancellable: AnyCancellable?

    init() {
        // store 改变 → 中继到 vm，让 SwiftUI 通过 vm.xxx 读取的字段也能感知变化
        cancellable = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: - 数据派生（全部转发到 store）
    var loadState: LoadState { store.loadState }
    var hasLoadedOnce: Bool { store.hasLoadedOnce }

    var displayName: String { store.displayName }
    var userId: String { store.userId }
    var ageText: String { store.ageText }
    var countryFlag: String { store.countryFlag }
    var countryText: String { store.countryText }
    var tierLabel: String { store.tierLabel }
    var ratePerMin: Int { store.ratePerMin }
    var iconURL: URL? { store.iconURL }
    var bio: String { store.bio }

    var photos: [MediaAsset] { store.photos }
    var videos: [MediaAsset] { store.videos }
    var photosTotal: Int { store.photos.count }
    var videosTotal: Int { store.videos.count }
    var giftList: [GiftItem] { store.giftList }

    var followingCount: Int { store.followingCount }
    var followersCount: Int { store.followersCount }
    var friendsCount: Int { store.friendsCount }

    // MARK: - 操作转发
    func loadIfNeeded() async { await store.loadIfNeeded() }
    func refresh() async { await store.refresh() }

    // MARK: - 静态 Helper 透传（view 子组件历史调用点保留）
    static func flagEmoji(from countryCode: String) -> String {
        AnchorInfoStore.flagEmoji(from: countryCode)
    }
}

/// 内容 tab 选项。
enum ProfileTab: CaseIterable, Hashable {
    case album, gifts, moment

    var title: String {
        switch self {
        case .album:  return L10n.profileTabAlbum
        case .gifts:  return L10n.profileTabGifts
        case .moment: return L10n.profileTabMoment
        }
    }
}
