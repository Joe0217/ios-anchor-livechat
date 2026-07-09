import SwiftUI

/// 用户卡片右侧操作按钮类型。设计稿展示 4 种态，对应 H5 `CCommunicationBtns` 的按钮组：
/// - chat: 绿青聊天泡（默认私聊入口）
/// - liveAction: 圆形粉橙摄像机（用户当前在直播）
/// - matchAction: 粉色心形 Match
/// - offlineToggle: 紫粉胶囊"Offline"（在线状态切换）
///
/// 接口接入阶段所有卡片暂用 `.chat` 默认态；其他态由用户业务状态推断（待 H 里程碑接入）。
enum LiveListUserAction: Hashable {
    case chat
    case liveAction
    case matchAction
    case offlineToggle
}

/// 用户卡片右侧的操作按钮。统一处理 4 种态：chat / liveAction / matchAction / offlineToggle。
/// 全部用切图（艺术嵌在 PNG 内），接口接入阶段点击无业务响应（待 H 里程碑接入私聊/视频通话/Match 跳转）。
struct LiveListActionButton: View {
    let action: LiveListUserAction

    var body: some View {
        Button {
            // 占位：业务跳转待 H 里程碑
        } label: {
            content
        }
        .buttonStyle(.plain)
        // 注意：不要用 .disabled(true)，SwiftUI 会自动把 disabled 按钮 label 灰化导致
        // 彩色切图变成灰色。空 action 已经足够"无响应"，无需额外禁用。
        .accessibilityLabel(a11yLabel)
    }

    @ViewBuilder
    private var content: some View {
        switch action {
        case .chat:
            Image("liveListChat")
                .resizable()
                .scaledToFit()
                .frame(width: Theme.Metric.liveListActionSize, height: Theme.Metric.liveListActionSize)
        case .liveAction:
            Image("liveListLiveAction")
                .resizable()
                .scaledToFit()
                .frame(width: Theme.Metric.liveListActionSize + 4, height: Theme.Metric.liveListActionSize + 4)
        case .matchAction:
            Image("liveListMatch")
                .resizable()
                .scaledToFit()
                .frame(width: Theme.Metric.liveListActionSize + 8, height: Theme.Metric.liveListActionSize + 8)
        case .offlineToggle:
            // 切图本身是横向胶囊（宽 ≈ 高 × 2.4），按宽度比例渲染
            Image("liveListOfflineToggle")
                .resizable()
                .scaledToFit()
                .frame(width: 78, height: 32)
        }
    }

    private var a11yLabel: String {
        switch action {
        case .chat:          return L10n.liveListActionChat
        case .liveAction:    return L10n.liveListActionLive
        case .matchAction:   return L10n.liveListActionMatch
        case .offlineToggle: return L10n.liveListActionOffline
        }
    }
}
