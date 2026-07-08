import SwiftUI

/// 通用媒体格（I-spec §7.2）。相册 / 视频 / 来电视频共用。
///
/// 显示：CachedAsyncImage（对齐 `ProfileMediaGrid` pattern，本地缓存 + placeholder 平滑）
/// 交互：
/// - 点击 tile 主体（idle 且有 URL）→ `onPreview` 触发父层弹全屏预览
/// - 点击右上 ×  → `onRemove` 删除
/// - 点击 failed 蒙层的重试按钮 → `onRetry` 重试上传
///
/// 4 种叠加态：normal / uploading（半透明黑蒙层 + spinner）/ failed（× 重试）/ 视频播放三角
struct MediaTile: View {
    let item: DraftMediaItem
    let showsCoverPlayIcon: Bool
    let cornerRadius: CGFloat
    let onRemove: () -> Void
    let onRetry: () -> Void
    let onPreview: () -> Void

    init(item: DraftMediaItem,
         showsCoverPlayIcon: Bool = false,
         cornerRadius: CGFloat = 8,
         onRemove: @escaping () -> Void,
         onRetry: @escaping () -> Void = {},
         onPreview: @escaping () -> Void = {}) {
        self.item = item
        self.showsCoverPlayIcon = showsCoverPlayIcon
        self.cornerRadius = cornerRadius
        self.onRemove = onRemove
        self.onRetry = onRetry
        self.onPreview = onPreview
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 底层：图片 / 占位（可点击触发预览）
            imageBase
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .onTapGesture {
                    // 仅 idle 且有可预览 URL 才响应
                    if case .idle = item.uploadState, !previewURLString.isEmpty {
                        onPreview()
                    }
                }

            // 上传中蒙层
            if case .uploading = item.uploadState {
                Color.black.opacity(0.4)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .allowsHitTesting(false)
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            } else if item.isServerReviewing || item.isServerRejected {
                // 服务端 vaild 审核态：底部小胶囊标签（用户需求 2026-07-08 v2：从左上角改到底部）
                // 不用全 tile 蒙层，图内容仍可见；胶囊自带背景不干扰图片
                serverReviewBadge
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 4)
                    .allowsHitTesting(false)
            }

            // 失败态覆盖
            if case .failed = item.uploadState {
                Button(action: onRetry) {
                    ZStack {
                        Color.black.opacity(0.55)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        VStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("Retry")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // 视频播放三角（仅 idle 态显示）
            if showsCoverPlayIcon, case .idle = item.uploadState {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }

            // 右上 × 删除
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .background(Circle().fill(Color.black.opacity(0.4)))
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Sub views

    private var imageBase: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.black.opacity(0.3))
            .overlay(imageContent)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var imageContent: some View {
        if !previewURLString.isEmpty, let url = URL(string: previewURLString) {
            CachedAsyncImage(url: url, contentMode: .fill) {
                Color.clear
            }
        } else {
            Color.clear
        }
    }

    /// 视频优先 coverUrl；图片用 url
    private var previewURLString: String {
        if showsCoverPlayIcon, let cover = item.coverUrl, !cover.isEmpty {
            return cover
        }
        return item.url
    }

    /// 服务端审核态标签 —— **左上角小胶囊**（用户需求 2026-07-08）
    ///
    /// 与初版全 tile 蒙层不同：胶囊自带黑色半透明底色，图内容不被完全遮挡；
    /// 位置固定左上角（tile 右上是 × 删除按钮，避开视觉冲突）。
    private var serverReviewBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: item.isServerReviewing ? "clock.fill" : "xmark.octagon.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(item.isServerReviewing ? L10n.profileMediaReviewing : L10n.profileMediaRejected)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
    }
}

#Preview {
    HStack(spacing: 12) {
        MediaTile(
            item: DraftMediaItem(id: "1", serverId: 1, url: "https://picsum.photos/200", coverUrl: nil, uploadState: .idle),
            onRemove: {}, onRetry: {}, onPreview: {}
        )
        .frame(width: 100, height: 100)

        MediaTile(
            item: DraftMediaItem(id: "2", serverId: nil, url: "", coverUrl: nil, uploadState: .uploading(localId: "x")),
            onRemove: {}, onRetry: {}, onPreview: {}
        )
        .frame(width: 100, height: 100)

        MediaTile(
            item: DraftMediaItem(id: "3", serverId: nil, url: "", coverUrl: nil, uploadState: .failed(message: "timeout")),
            onRemove: {}, onRetry: {}, onPreview: {}
        )
        .frame(width: 100, height: 100)
    }
    .padding()
    .background(Theme.Palette.screenBackground)
}
