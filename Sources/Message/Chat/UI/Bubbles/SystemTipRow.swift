import SwiftUI

/// weakTxtType 数字系统提示（H-2 spec §2.4，对齐 H5 `msgItem.vue:166` guideTip 样式）。
///
/// **视觉**：**居中**灰白半透明字条（非左右方向的 bubble），高 21pt 圆角 12 padding 4/8。
/// **weakType**：-4 关注 / 103/104 裂变 / 156/157 主播活动 —— 目前统一样式，未来可按 type 分色
struct SystemTipRow: View {
    let text: String
    let weakType: Int

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Text(text.isEmpty ? placeholderText : text)
                .font(.system(size: 12))
                .foregroundStyle(ChatPalette.whiteAlpha60)
                .padding(.horizontal, 8)
                .frame(minHeight: 21)
                .background(ChatPalette.tipBackground, in: RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    /// 后端缺文案时的占位（不同 weakType 显示不同类型标识；H-3 阶段接 L10n）
    private var placeholderText: String {
        switch weakType {
        case -4: return "New follower"
        case 103, 104: return "Bonus activity"
        case 156, 157: return "Anchor event"
        default: return "System notice"
        }
    }
}
