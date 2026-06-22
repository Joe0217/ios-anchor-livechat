import SwiftUI

/// List 子页顶部 Online / Prime 二选一切换器。
/// 容器：圆角胶囊深底；选中半段：紫→粉横向渐变 + 黄字；未选中：透明 + 白字。
struct LiveListSegmentSwitcher: View {
    @Binding var selected: LiveListSegment

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // 选中胶囊（用 offset 实现两段位移动画）
                Capsule()
                    .fill(Theme.Gradients.liveListSwitcherSelected)
                    .frame(width: geo.size.width / 2)
                    .offset(x: selected == .online ? 0 : geo.size.width / 2)
                    .animation(.easeInOut(duration: 0.18), value: selected)

                HStack(spacing: 0) {
                    ForEach(LiveListSegment.allCases, id: \.self) { segment in
                        segmentButton(segment)
                    }
                }
            }
        }
        .frame(height: Theme.Metric.liveListSwitcherHeight)
        .padding(2)
        .background(
            Capsule().fill(Theme.Palette.liveListSwitcherTrack)
        )
    }

    private func segmentButton(_ segment: LiveListSegment) -> some View {
        let isSelected = segment == selected
        return Button {
            selected = segment
        } label: {
            Text(segment.label)
                .font(Theme.Typography.liveListSwitcher)
                .foregroundStyle(
                    isSelected
                        ? Theme.Palette.liveListSwitcherSelected
                        : Theme.Palette.liveListSwitcherUnselected
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
