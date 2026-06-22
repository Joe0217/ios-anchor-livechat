import SwiftUI

/// 工具区：标题行（Match 灰球 + 在线开关）+ 4 列工具图标网格。
struct ToolsSection: View {
    @ObservedObject var vm: WorkViewModel

    /// 工具项（图标资源名 + 标签）。顺序与设计稿一致。
    private let tools: [(icon: String, label: String)] = [
        ("toolHi", L10n.toolHi),
        ("toolGoLive", L10n.toolGoLive),
        ("toolMatch", L10n.toolMatch),
        ("toolTask", L10n.toolTask),
        ("toolBeauty", L10n.toolBeauty),
        ("toolPoints", L10n.toolPoints),
        ("toolGiftMessage", L10n.toolGiftMessage),
        ("toolProfileUpdate", L10n.toolProfileUpdate),
        ("toolInvite", L10n.toolInvite),
        ("toolWorkingGuide", L10n.toolWorkingGuide),
        ("toolBackpack", L10n.toolBackpack),
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8),
                                count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Rectangle()
                .fill(Theme.Palette.divider)
                .frame(height: 1)

            LazyVGrid(columns: columns, alignment: .center, spacing: Theme.Metric.toolRowSpacing) {
                ForEach(tools.indices, id: \.self) { i in
                    toolCell(icon: tools[i].icon, label: tools[i].label)
                }
            }
            .padding(.top, 4)
        }
        .padding(Theme.Metric.cardPadding)
        .background(Theme.Palette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.bigCard, style: .continuous))
    }

    // MARK: - 标题行
    private var header: some View {
        HStack(spacing: 10) {
            Text(L10n.workTools)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(.white)
            Spacer()
            Image("toolsMatchGrey")
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            // 在线开关：纯代码绘制，支持开/关两态
            OnlineToggleView(isOn: $vm.isOnline)
        }
    }

    // MARK: - 单个工具
    private func toolCell(icon: String, label: String) -> some View {
        VStack(spacing: 8) {
            Image(icon)
                .resizable()
                .scaledToFit()
                .frame(width: Theme.Metric.toolTile, height: Theme.Metric.toolTile)
                .accessibilityHidden(true)
            Text(label)
                .font(Theme.Typography.toolLabel)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
