import SwiftUI

/// H-3 被拒消息提示条（spec §1.4 / §4.8 / §F-25/F-26）。
///
/// **对齐 H5** `msgItem.vue:336-338`：
/// - `data.status === 'refused'`（iOS `ChatMessageStatus.refused`，NIM SDK 错误码 7101 已由 NIMChatAdapter 映射）
/// - UI: `w327 rounded-12 px-12 py-6 text-12 fw-500 text-black bg-rgba(0,0,0,0.04)`
/// - 无交互（不可 tap 不可 dismiss）
/// - 位置：气泡下方紧跟（由 ChatMessageRow 在 msg.isOutgoing && msg.status == .refused 时挂）
///
/// **文案 L10n**：`chat.refusedTip`（en/ar/tr 三语，Step 1b 补对应 key）
struct RefusedInlineTip: View {
    var body: some View {
        Text(L10n.chatRefusedTip)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(width: 327)
            .background(Color.black.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    RefusedInlineTip()
        .padding()
        .background(Color.white)
}
