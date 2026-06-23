import SwiftUI

/// Photos / Videos section：标题 + 3 列网格。
///
/// cell 用 AsyncImage 加载远端缩略图（图片用 url，视频用 coverUrl ?? url）；
/// 视频叠加播放图标；审核态（vaild=2 审核中 / 3 已拒）显示对应蒙层 + 徽章。
/// `onTap` 由父 View 注入，触发后弹出 MediaPreviewView 全屏预览。
struct ProfileMediaGrid: View {
    let title: String
    let items: [MediaAsset]
    let isVideoGrid: Bool
    var onTap: ((MediaAsset) -> Void)? = nil

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

            if items.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: Theme.Metric.profileGridGap) {
                    ForEach(items) { item in
                        Button {
                            onTap?(item)
                        } label: {
                            cell(for: item)
                        }
                        .buttonStyle(.plain)
                        .disabled(onTap == nil || item.vaild == 3) // 已拒禁用点击
                    }
                }
                .padding(.horizontal, Theme.Metric.profileDescPadding)
            }
        }
    }

    private var emptyState: some View {
        // 同样占 3 列网格高度的空态，避免 Album tab 上下抖动
        HStack {
            Spacer()
            Text(L10n.profileEmptyPlaceholder)
                .font(.system(size: 12))
                .foregroundColor(Theme.Palette.profileTabInactive)
            Spacer()
        }
        .padding(.vertical, 28)
        .padding(.horizontal, Theme.Metric.profileDescPadding)
    }

    private func cell(for item: MediaAsset) -> some View {
        let imageURL = URL(string: (isVideoGrid ? item.coverUrl : item.url) ?? "")
        let isReviewing = item.vaild == 2
        let isRejected = item.vaild == 3

        return ZStack {
            // 远端图：缓存版 AsyncImage，切 tab 回来无重新加载
            CachedAsyncImage(url: imageURL, contentMode: .fill) {
                Theme.Palette.profileGridPlaceholder
            }

            // 视频播放角标
            if isVideoGrid {
                Image("profileVideoPlay")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
            }

            // 审核态蒙层 + 徽章
            if isReviewing || isRejected {
                Color.black.opacity(0.55)
                VStack(spacing: 4) {
                    Image(systemName: isReviewing ? "clock.fill" : "xmark.octagon.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                    Text(isReviewing ? L10n.profileMediaReviewing : L10n.profileMediaRejected)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                }
                .padding(6)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.profileGridCell, style: .continuous))
        .accessibilityLabel(cellA11yLabel(item: item, isReviewing: isReviewing, isRejected: isRejected))
    }

    private func cellA11yLabel(item: MediaAsset, isReviewing: Bool, isRejected: Bool) -> String {
        let baseType = isVideoGrid ? L10n.profileVideoCellA11y : L10n.profilePhotoCellA11y
        if isReviewing { return "\(baseType), \(L10n.profileMediaReviewing)" }
        if isRejected  { return "\(baseType), \(L10n.profileMediaRejected)" }
        return baseType
    }
}
