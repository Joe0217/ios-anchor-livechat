import SwiftUI

/// 用户卡片右侧操作按钮类型。设计稿展示 5 种态，对应 H5 `CCommunicationBtns` 的按钮组：
/// - chat: 绿青聊天泡（默认私聊入口）
/// - videoCall: 紫红电话（1v1 视频通话；按 `CallAuthBridge.canCall` + prime segment 强制显示）
/// - liveAction: 圆形粉橙摄像机（用户当前在直播）
/// - matchAction: 粉色心形 Match
/// - offlineToggle: 紫粉胶囊"Offline"（在线状态切换）
///
/// `.chat` / `.videoCall` 已接入业务；`.liveAction` / `.matchAction` / `.offlineToggle` 待 H 里程碑接入。
enum LiveListUserAction: Hashable {
    case chat
    case videoCall
    case liveAction
    case matchAction
    case offlineToggle
}

/// 用户卡片右侧的操作按钮：纯 UI 容器 + tap 转发。业务由 `LiveListUserCard` 装配 `onTap` 闭包决定
/// （避免按钮内联多个 SDK / env 依赖，保持 SRP）。
struct LiveListActionButton: View {
    let action: LiveListUserAction
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            content
        }
        // `.borderless` 是本组件在 `LiveListUserCard` NavigationLink label 内独立响应 tap 的关键：
        // `.plain` 内嵌 Button 会被外层 NavigationLink 手势吞掉（真机点私聊/视频通话按钮时会 push
        // UserProfileView 而非触发 onTap）。父 view 也再叠一层 `.borderless` 是显式冗余保险。
        .buttonStyle(.borderless)
        // 注意：不要用 .disabled(true)，SwiftUI 会自动把 disabled 按钮 label 灰化导致
        // 彩色切图变成灰色。占位态由父 view 传空 onTap 无响应即可。
        .accessibilityLabel(a11yLabel)
    }

    @ViewBuilder
    private var content: some View {
        switch action {
        case .chat:
            CDNAssetImage("liveListChat")
                .resizable()
                .scaledToFit()
                .frame(width: Theme.Metric.liveListActionSize, height: Theme.Metric.liveListActionSize)
        case .videoCall:
            CDNAssetImage("liveListVideoCall")
                .resizable()
                .scaledToFit()
                .frame(width: Theme.Metric.liveListActionSize, height: Theme.Metric.liveListActionSize)
        case .liveAction:
            CDNAssetImage("liveListLiveAction")
                .resizable()
                .scaledToFit()
                .frame(width: Theme.Metric.liveListActionSize + 4, height: Theme.Metric.liveListActionSize + 4)
        case .matchAction:
            CDNAssetImage("liveListMatch")
                .resizable()
                .scaledToFit()
                .frame(width: Theme.Metric.liveListActionSize + 8, height: Theme.Metric.liveListActionSize + 8)
        case .offlineToggle:
            // 切图本身是横向胶囊（宽 ≈ 高 × 2.4），按宽度比例渲染
            CDNAssetImage("liveListOfflineToggle")
                .resizable()
                .scaledToFit()
                .frame(width: 78, height: 32)
        }
    }

    private var a11yLabel: String {
        switch action {
        case .chat:          return L10n.liveListActionChat
        case .videoCall:     return L10n.liveListActionVideoCall
        case .liveAction:    return L10n.liveListActionLive
        case .matchAction:   return L10n.liveListActionMatch
        case .offlineToggle: return L10n.liveListActionOffline
        }
    }
}
