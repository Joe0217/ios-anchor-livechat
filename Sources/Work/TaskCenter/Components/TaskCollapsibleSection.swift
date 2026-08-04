import SwiftUI

/// Weekly 专用折叠壳。对齐 H5 [`CollapsibleSection.vue`](../../../../../Desktop/HN/anchor-livechat-h5/src/views/task/components/CollapsibleSection.vue)。
/// 用于 tycoonTask / integralTask 两个 Weekly 独有区块。
///
/// **视觉**:标题行(切图 icon + name + 右侧 chevron)+ 展开内容;折叠时隐藏内容。
/// 图标用 imageset(切图),与 Module Card 的 title bar 风格一致。
struct TaskCollapsibleSection<Content: View>: View {
    let title: String
    /// 图标 imageset 名(切图)
    let iconAsset: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    CDNAssetImage(iconAsset)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(hex: 0xFFE600))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(hex: 0x251A3A))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
