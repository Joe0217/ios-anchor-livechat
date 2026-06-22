import SwiftUI

/// 用户卡片右侧的操作按钮。统一处理 4 种态：chat / liveAction / matchAction / offlineToggle。
/// 全部用切图（艺术嵌在 PNG 内），本期点击无业务响应。
struct LiveListActionButton: View {
    let action: LiveListUserAction

    var body: some View {
        Button {
            // 占位：静态还原期无业务响应
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
