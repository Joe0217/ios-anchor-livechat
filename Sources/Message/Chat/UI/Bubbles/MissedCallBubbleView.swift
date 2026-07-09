import SwiftUI

/// MISSED_CALLS_RECORD 未接来电气泡（H-2 spec §1，对齐 H5 `msgItem.vue:297-314`）。
///
/// **视觉**：常规 bubble 尺寸（同文字气泡），phone icon + 状态文案；主播端仅收到（isOutgoing=false）
struct MissedCallBubbleView: View {
    let kind: MissedCallKind
    let isOutgoing: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "phone.badge.checkmark")
                .font(.system(size: 14))
                .foregroundStyle(.white)
            Text(statusText)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: ChatConstants.textBubbleMaxWidth, alignment: .leading)
        .background(isOutgoing ? ChatPalette.myBubbleBackground : ChatPalette.peerBubbleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var statusText: String {
        switch kind {
        case .missed: return "Missed"
        case .canceled: return "Canceled"
        case .rejected: return "Rejected"
        }
    }
}
