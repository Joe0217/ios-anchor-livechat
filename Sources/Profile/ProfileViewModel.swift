import Foundation
import SwiftUI

/// Profile 屏占位数据源（设计稿还原阶段不接后端，仅承载视觉所需字段）。
///
/// 后续接入用户接口时，由 SessionStore.user / 用户详情接口替换 placeholder 字段；
/// View 只读 @Published，副作用全收敛在此处。
@MainActor
final class ProfileViewModel: ObservableObject {
    // 头部
    @Published var displayName: String = "Dawei"
    @Published var userId: String      = "100000360"
    @Published var ageText: String     = "24"
    @Published var countryFlag: String = "🇺🇸"
    @Published var tierLabel: String   = "SS"
    @Published var rateText: String    = "800/min"

    // stats
    @Published var followingCount: Int = 13235
    @Published var followersCount: Int = 354
    @Published var friendsCount: Int   = 354

    // 描述
    @Published var bio: String = "✨ Your Starry Guide | Tap “+Follow” to catch daily heartbeats 🪐 | 📸 High-Sweet Live Blind Box launched | Generating your story’s BGM 🎵"

    // 内容 tab
    @Published var selectedTab: ProfileTab = .album

    // 相册/视频数据（用本地占位封面色填充网格；接入相册接口时替换为远端 URL）
    @Published var photos: [ProfileMediaItem] = ProfileMediaItem.previewPhotos(count: 6)
    @Published var videos: [ProfileMediaItem] = ProfileMediaItem.previewVideos(count: 6)
    @Published var photosTotal: Int = 9
    @Published var videosTotal: Int = 6
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

/// 媒体网格 cell 数据（接入真实接口前用 hue 区分占位）。
struct ProfileMediaItem: Identifiable, Hashable {
    let id: UUID = UUID()
    /// 占位封面 hue（0..1），接入后替换为 URL/AsyncImage
    let placeholderHue: Double
    /// 是否视频（决定是否叠加播放图标）
    let isVideo: Bool

    static func previewPhotos(count: Int) -> [ProfileMediaItem] {
        (0..<count).map { i in
            ProfileMediaItem(placeholderHue: Double(i) / Double(max(count, 1)), isVideo: false)
        }
    }

    static func previewVideos(count: Int) -> [ProfileMediaItem] {
        // 视频占位 hue 整体偏移半轮，与 photos 色相错开，避免肉眼看像重复封面
        (0..<count).map { i in
            let hue = (Double(i) / Double(max(count, 1)) + 0.5).truncatingRemainder(dividingBy: 1.0)
            return ProfileMediaItem(placeholderHue: hue, isVideo: true)
        }
    }
}
