import SwiftUI

/// List 子页顶部 Online/Prime 切换。
enum LiveListSegment: CaseIterable, Hashable {
    case online, prime

    var label: String {
        switch self {
        case .online: return L10n.liveListSegmentOnline
        case .prime:  return L10n.liveListSegmentPrime
        }
    }
}

/// 用户卡片右侧操作类型。设计稿展示 5 张卡片演示了 4 种态：
/// - chat: 绿青聊天泡（占位 1/2/3/5 默认态）
/// - liveAction: 圆形粉橙摄像机（"正在直播"指示）
/// - matchAction: 粉色心形 Match
/// - offlineToggle: 紫粉胶囊"Offline"（带白圆点的状态切换，本期仅 Offline 单态）
enum LiveListUserAction: Hashable {
    case chat
    case liveAction
    case matchAction
    case offlineToggle
}

/// 单个用户卡片占位数据。本期静态还原；接入接口后由后端下发。
struct LiveListUser: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let avatarColorTop: Color
    let avatarColorBottom: Color
    let levelText: String
    let location: String
    let action: LiveListUserAction
}

/// List 子页视图模型：分段切换 + 占位卡片列表。
///
/// 数据全部硬编码 mock，**不进 i18n**：用户名 / 等级 / 国名 等正式版本由后端下发，
/// 后续接入 anchor 列表接口后异步替换。
@MainActor
final class LiveListViewModel: ObservableObject {
    @Published var segment: LiveListSegment = .online

    /// 5 张占位卡片，演示设计稿 4 种动作态
    let users: [LiveListUser] = [
        LiveListUser(
            name: "Garrett",
            avatarColorTop: Color(hex: 0xE7B5C8),
            avatarColorBottom: Color(hex: 0x6E3A4A),
            levelText: "Lv.5",
            location: "Canada",
            action: .chat
        ),
        LiveListUser(
            name: "Garrett Steven...",
            avatarColorTop: Color(hex: 0xE7A9B6),
            avatarColorBottom: Color(hex: 0x5D2C3D),
            levelText: "Lv.7",
            location: "Canada",
            action: .chat
        ),
        LiveListUser(
            name: "Garrett Garrett",
            avatarColorTop: Color(hex: 0xE6B0A3),
            avatarColorBottom: Color(hex: 0x4F2A35),
            levelText: "Lv.12",
            location: "Canada",
            action: .chat
        ),
        LiveListUser(
            name: "Garrett Garrett",
            avatarColorTop: Color(hex: 0xE5BFA8),
            avatarColorBottom: Color(hex: 0x483042),
            levelText: "Lv.20",
            location: "Canada",
            action: .liveAction
        ),
        LiveListUser(
            name: "Garrett",
            avatarColorTop: Color(hex: 0xE5A6B4),
            avatarColorBottom: Color(hex: 0x4A283C),
            levelText: "Lv.32",
            location: "Canada",
            action: .matchAction
        ),
    ]
}
