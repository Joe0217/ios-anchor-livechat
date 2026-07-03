import SwiftUI

/// Circle 内层 3 子 tab 条 (Official / Moment / Me)。
///
/// trial #1：占位实现，沿用 LiveTopBar 视觉风格简化版（无光带 / 无右侧 actions）。
/// 正式设计稿入仓后替换为还原版。
struct CircleSubTabBar: View {
    @Binding var selected: CircleSubTab

    var body: some View {
        HStack(spacing: 28) {
            ForEach(CircleSubTab.allCases, id: \.self) { tab in
                Button {
                    selected = tab
                } label: {
                    Text(tab.label)
                        .font(.system(
                            size: selected == tab ? 16 : 14,
                            weight: selected == tab ? .semibold : .regular
                        ))
                        .foregroundColor(selected == tab ? .white : .white.opacity(0.55))
                        .accessibilityAddTraits(selected == tab ? .isSelected : [])
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

#if DEBUG
struct CircleSubTabBar_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            CircleSubTabBar(selected: .constant(.official))
                .previewDisplayName("Official 选中")
            CircleSubTabBar(selected: .constant(.moment))
                .previewDisplayName("Moment 选中")
            CircleSubTabBar(selected: .constant(.me))
                .previewDisplayName("Me 选中")
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .previewLayout(.sizeThatFits)
    }
}
#endif
