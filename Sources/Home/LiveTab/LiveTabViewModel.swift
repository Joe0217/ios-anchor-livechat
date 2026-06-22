import SwiftUI

/// Live Tab 顶部 4 个子分页。
enum LiveSubTab: CaseIterable, Hashable {
    case live, list, match, cysle

    /// 设计稿标签（视觉文本，i18n 走 L10n）
    var label: String {
        switch self {
        case .live:  return L10n.liveSubTabLive
        case .list:  return L10n.liveSubTabList
        case .match: return L10n.liveSubTabMatch
        case .cysle: return L10n.liveSubTabCysle
        }
    }
}

/// 直播卡片占位数据。本期仅做静态还原，无真实接口；
/// 卡片背景图、头像在无切图素材下用渐变 + 系统人像占位。
struct LiveAnchorCard: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let viewerCount: String
    /// 卡片占位背景（顶层柔色块，模拟主播自拍底色）
    let placeholderTop: Color
    /// 卡片占位背景（底层）
    let placeholderBottom: Color
    /// 右下角是否贴 "Live" 徽章（设计稿仅最后一张）
    let showLiveBadge: Bool
}

/// Live Tab 视图模型：顶部选中态 + 占位卡片列表。
///
/// 数据全部硬编码 mock，且**有意不进 i18n**：
/// 这些字段（用户昵称、礼物动作描述、活动文案、观看人数）正式版本由后端下发，
/// 后续接入 Live 接口后通过 `@Published var notice: LiveNoticeData?` 等异步替换。
/// 现阶段仅供静态还原展示用。
@MainActor
final class LiveTabViewModel: ObservableObject {
    @Published var selectedSubTab: LiveSubTab = .live
    @Published var rankCount: String = "+100K"
    @Published var hasUnreadNotice: Bool = true

    /// 礼物通知条占位（设计稿仅 1 条）
    let notice = LiveNoticeData(
        userName: "Emma",
        action: "sends out a super rocket",
        amount: "99999"
    )

    /// 圣诞活动 banner 占位
    let banner = LiveBannerData(
        title: "100 FREE SPINS\nTHIS CHRISTMAS",
        period: "December 11 - December 18, 2024"
    )

    /// 直播卡片占位（4 张，设计稿同款 Sarah，最后一张带 Live 徽章）
    let cards: [LiveAnchorCard] = [
        LiveAnchorCard(
            name: "Sarah",
            viewerCount: "2.8k",
            placeholderTop: Color(hex: 0xC79988),
            placeholderBottom: Color(hex: 0x5E3D4D),
            showLiveBadge: false
        ),
        LiveAnchorCard(
            name: "Sarah",
            viewerCount: "2.8k",
            placeholderTop: Color(hex: 0xE9C9A2),
            placeholderBottom: Color(hex: 0x6E4E32),
            showLiveBadge: false
        ),
        LiveAnchorCard(
            name: "Sarah",
            viewerCount: "2.8k",
            placeholderTop: Color(hex: 0xE0B5A0),
            placeholderBottom: Color(hex: 0x4A2C3A),
            showLiveBadge: false
        ),
        LiveAnchorCard(
            name: "Sarah",
            viewerCount: "2.8k",
            placeholderTop: Color(hex: 0xD9A4A5),
            placeholderBottom: Color(hex: 0x382230),
            showLiveBadge: true
        ),
    ]
}

/// 礼物通知条数据
struct LiveNoticeData: Hashable {
    let userName: String
    let action: String
    let amount: String
}

/// 圣诞 banner 数据
struct LiveBannerData: Hashable {
    let title: String
    let period: String
}
