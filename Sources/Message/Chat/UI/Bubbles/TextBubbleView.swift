import SwiftUI

/// 文字消息气泡（H-2 spec §1 表 1.1 + Batch 3.9 chatBubble 对齐 H5 `msgItem.vue:218-231`）。
///
/// **视觉规范**：
/// - 默认（无 chatBubble）：我方 `#2D1F47` / 对方 `#4E1B4D` 背景 + 圆角 12
/// - 有 chatBubble：主播穿戴的点九图（NinePatchImageView，H5 border-image-slice 63 87 63 87 fill）
/// - padding 8/12、max-w 210、字号 14 行高 18 白色
struct TextBubbleView: View {
    let text: String
    let isOutgoing: Bool
    /// 主播穿戴的气泡装扮 URL（H-3 spec §1.6）—— 非 nil 走点九图背景，nil 走默认色底
    var chatBubble: URL? = nil
    /// 翻译后文本；非 nil 时在原文下方显示（内存态,不持久化，对齐 H5 chatStore.translatedMap）。
    var translatedText: String? = nil
    var body: some View {
        PublicChatContentHuggingLayout(maxWidth: ChatConstants.textBubbleMaxWidth) {
            VStack(alignment: .leading, spacing: 4) {
                // 原文
                Text(text)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(.white)

                // 已翻译:分隔线 + 译文(对齐 H5 border-t-1-black + mt-4 pt4)
                if let tx = translatedText {
                    Rectangle()
                        .fill(.white.opacity(0.2))
                        .frame(height: 0.5)
                        .padding(.top, 2)
                    Text(tx)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .foregroundStyle(.white)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, chatBubble == nil ? 12 : ChatSkinMetrics.horizontalContentInset)
            .padding(.vertical, chatBubble == nil ? 8 : ChatSkinMetrics.verticalContentInset)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                if let url = chatBubble {
                    // H5 custom class 强制 transparent / border-radius: 0，不叠默认圆角色底。
                    NinePatchImageView(url: url)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(defaultBubbleColor)
                }
            }
        }
        // H5 自定义皮肤 `border-radius: 0`，不得裁掉点九图自身的角和挂饰。
    }

    private var defaultBubbleColor: Color {
        isOutgoing ? ChatPalette.myBubbleBackground : ChatPalette.peerBubbleBackground
    }
}
