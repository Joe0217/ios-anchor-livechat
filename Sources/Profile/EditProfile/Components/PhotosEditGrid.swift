import SwiftUI
import PhotosUI

/// 相册照片网格（I-spec §7.2）。3 列 LazyVGrid + MediaTile × N + AddMediaTile。
///
/// 3 列等宽 —— 对齐 rule `swiftui-shared-coordinate-same-container.md`，LazyVGrid
/// 天然保证同一 layout container，所有 tile 严格共坐标系。
///
/// `isRefreshing` = SWR 后台刷新中；hydrate 时 items 为空（缓存不 hydrate 媒体），
/// 显示 3 个 skeleton 占位 tile 避免"进入编辑页空 grid → 突然冒出图"的视觉跳变。
struct PhotosEditGrid: View {
    let items: [DraftMediaItem]
    let isRefreshing: Bool
    let onPick: (PhotosPickerItem) -> Void
    let onRemove: (String) -> Void
    let onRetry: (String) -> Void
    let onPreview: (DraftMediaItem) -> Void

    init(items: [DraftMediaItem],
         isRefreshing: Bool = false,
         onPick: @escaping (PhotosPickerItem) -> Void,
         onRemove: @escaping (String) -> Void,
         onRetry: @escaping (String) -> Void,
         onPreview: @escaping (DraftMediaItem) -> Void) {
        self.items = items
        self.isRefreshing = isRefreshing
        self.onPick = onPick
        self.onRemove = onRemove
        self.onRetry = onRetry
        self.onPreview = onPreview
    }

    private let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(items) { item in
                MediaTile(
                    item: item,
                    onRemove: { onRemove(item.id) },
                    onRetry: { onRetry(item.id) },
                    onPreview: { onPreview(item) }
                )
                .aspectRatio(1, contentMode: .fit)
            }
            if isRefreshing && items.isEmpty {
                // 3 个 skeleton 占位：SWR refresh 未回，photos 尚未填充
                ForEach(0..<3, id: \.self) { _ in
                    MediaSkeletonTile()
                        .aspectRatio(1, contentMode: .fit)
                }
            } else if items.count < EditProfileLimits.photosMaxCount {
                AddMediaTile(matching: .images, disabled: false) { picker in
                    onPick(picker)
                }
                .aspectRatio(1, contentMode: .fit)
            }
        }
    }
}

/// 视频网格（对齐相册结构，仅过滤器 + max 差异）。
struct VideosEditGrid: View {
    let items: [DraftMediaItem]
    let isRefreshing: Bool
    let onPick: (PhotosPickerItem) -> Void
    let onRemove: (String) -> Void
    let onRetry: (String) -> Void
    let onPreview: (DraftMediaItem) -> Void

    init(items: [DraftMediaItem],
         isRefreshing: Bool = false,
         onPick: @escaping (PhotosPickerItem) -> Void,
         onRemove: @escaping (String) -> Void,
         onRetry: @escaping (String) -> Void,
         onPreview: @escaping (DraftMediaItem) -> Void) {
        self.items = items
        self.isRefreshing = isRefreshing
        self.onPick = onPick
        self.onRemove = onRemove
        self.onRetry = onRetry
        self.onPreview = onPreview
    }

    private let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(items) { item in
                MediaTile(
                    item: item,
                    showsCoverPlayIcon: true,
                    onRemove: { onRemove(item.id) },
                    onRetry: { onRetry(item.id) },
                    onPreview: { onPreview(item) }
                )
                .aspectRatio(1, contentMode: .fit)
            }
            if isRefreshing && items.isEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    MediaSkeletonTile()
                        .aspectRatio(1, contentMode: .fit)
                }
            } else if items.count < EditProfileLimits.videosMaxCount {
                AddMediaTile(matching: .videos, disabled: false) { picker in
                    onPick(picker)
                }
                .aspectRatio(1, contentMode: .fit)
            }
        }
    }
}

/// 来电视频单卡（max 1）。
struct CallVideoEditCell: View {
    let item: DraftMediaItem?
    let isRefreshing: Bool
    let onPick: (PhotosPickerItem) -> Void
    let onRemove: () -> Void
    let onRetry: () -> Void
    let onPreview: (DraftMediaItem) -> Void

    init(item: DraftMediaItem?,
         isRefreshing: Bool = false,
         onPick: @escaping (PhotosPickerItem) -> Void,
         onRemove: @escaping () -> Void,
         onRetry: @escaping () -> Void,
         onPreview: @escaping (DraftMediaItem) -> Void) {
        self.item = item
        self.isRefreshing = isRefreshing
        self.onPick = onPick
        self.onRemove = onRemove
        self.onRetry = onRetry
        self.onPreview = onPreview
    }

    var body: some View {
        HStack(spacing: 12) {
            if let item {
                MediaTile(
                    item: item,
                    showsCoverPlayIcon: true,
                    cornerRadius: 10,
                    onRemove: onRemove,
                    onRetry: onRetry,
                    onPreview: { onPreview(item) }
                )
                .frame(width: 100, height: 100)
            } else if isRefreshing {
                // SWR refresh 未回，来电视频尚未加载 → 显示 skeleton 占位
                MediaSkeletonTile(cornerRadius: 10)
                    .frame(width: 100, height: 100)
            } else {
                AddMediaTile(matching: .videos, disabled: false) { picker in
                    onPick(picker)
                }
                .frame(width: 100, height: 100)
            }
            Spacer()
        }
    }
}

/// SWR 骨架占位 tile：refresh 期间替代空 slot 展示，避免"空 grid → 突然冒图"的视觉跳变。
///
/// 用 SwiftUI 系统 `.redacted(reason: .placeholder)` 让内容自带 shimmer 效果，不引入第三方。
private struct MediaSkeletonTile: View {
    var cornerRadius: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.black.opacity(0.15))
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.white.opacity(0.35))
            )
            .redacted(reason: .placeholder)
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 20) {
            EditProfileSectionCard(title: "Photos (2/9)") {
                PhotosEditGrid(
                    items: [
                        DraftMediaItem(id: "1", serverId: 1, url: "https://picsum.photos/200", coverUrl: nil, uploadState: .idle),
                        DraftMediaItem(id: "2", serverId: nil, url: "", coverUrl: nil, uploadState: .uploading(localId: "x")),
                    ],
                    onPick: { _ in }, onRemove: { _ in }, onRetry: { _ in }, onPreview: { _ in }
                )
            }
            EditProfileSectionCard(title: "Videos (0/6)") {
                VideosEditGrid(items: [], onPick: { _ in }, onRemove: { _ in }, onRetry: { _ in }, onPreview: { _ in })
            }
            EditProfileSectionCard(title: "Call Video") {
                CallVideoEditCell(item: nil, onPick: { _ in }, onRemove: {}, onRetry: {}, onPreview: { _ in })
            }
        }
        .padding()
    }
    .background(Theme.Palette.screenBackground)
}
