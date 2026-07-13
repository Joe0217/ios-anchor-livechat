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
    /// Batch 6.3.3：翻译后文本；非 nil 时替代 `text` 显示（内存态,不持久化，对齐 H5 chatStore.translatedMap）
    var translatedText: String? = nil
    /// Batch 6.3.3：长按翻译回调（对方消息才 non-nil；H5 chat/index.vue 仅对方消息长按可翻译）
    var onLongPressTranslate: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 原文
            Text(text)
                .font(.system(size: 14))
                .lineSpacing(4)
                .foregroundStyle(.white)

            // 对方消息 + 未翻译 → 展示"Translate"按钮(对齐 H5 msgItem.vue CTranslate)
            if let onTap = onLongPressTranslate, translatedText == nil {
                Button(action: onTap) {
                    Text(L10n.chatTranslate)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(hex: 0xC49BFF))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: ChatConstants.textBubbleMaxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            if let url = chatBubble {
                // 点九图背景(NinePatchImageView 内部 URLSession 拉取 + resizableImage(withCapInsets:) 拉伸)
                // 下载失败 → NinePatchImageView 显透明 → 默认色底叠在下层兜底
                ZStack {
                    defaultBubbleBackground
                    NinePatchImageView(url: url)
                }
            } else {
                defaultBubbleBackground
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // 长按仍触发翻译作为可选备用交互(iOS 惯例)
        .onLongPressGesture(minimumDuration: 0.5) {
            onLongPressTranslate?()
        }
    }

    private var defaultBubbleBackground: some View {
        (isOutgoing ? ChatPalette.myBubbleBackground : ChatPalette.peerBubbleBackground)
    }
}
