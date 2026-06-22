import SwiftUI

/// Photos / Videos section：标题 + 3 列网格。
/// 视频 cell 中央叠加播放图标（profileVideoPlay 切图）。
struct ProfileMediaGrid: View {
    let title: String
    let items: [ProfileMediaItem]

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Theme.Metric.profileGridGap),
            count: Theme.Metric.profileGridColumns
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(Theme.Typography.profileSection)
                .foregroundColor(Theme.Palette.profileSection)
                .padding(.horizontal, Theme.Metric.profileDescPadding)

            LazyVGrid(columns: columns, spacing: Theme.Metric.profileGridGap) {
                ForEach(items) { item in
                    cell(for: item)
                }
            }
            .padding(.horizontal, Theme.Metric.profileDescPadding)
        }
    }

    private func cell(for item: ProfileMediaItem) -> some View {
        ZStack {
            // 占位封面：用 hue 区分各 cell，接入相册接口后替换为 AsyncImage
            RoundedRectangle(cornerRadius: Theme.Radius.profileGridCell, style: .continuous)
                .fill(Color(hue: item.placeholderHue, saturation: 0.35, brightness: 0.55))

            if item.isVideo {
                Image("profileVideoPlay")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.profileGridCell, style: .continuous))
        .accessibilityLabel(item.isVideo ? L10n.profileVideoCellA11y : L10n.profilePhotoCellA11y)
    }
}
