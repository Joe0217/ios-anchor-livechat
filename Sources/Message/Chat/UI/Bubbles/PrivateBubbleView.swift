import SwiftUI

/// H-3 私密图片消息气泡（Batch 6.3.2 spec §F-4 / §F-5）。
///
/// **对齐 H5** `msgItem.vue` 私密图/视频消息叠加 lock/unlock icon：
/// - `.locked` (0)   → 中央大**锁** icon + 遮罩淡化图片
/// - `.unlocked` (1) → 中央**开锁** icon + 图片完整显示
/// - `.unknown`      → 无 icon（服务端未追加 lockStatus 兜底态）
struct PrivateImageBubbleView: View {
    let url: URL
    let lockStatus: PrivateLockStatus

    var body: some View {
        CachedAsyncImage(url: url, contentMode: .fill, persistent: true) {
            ChatPalette.cardBackground
                .overlay { ProgressView().tint(.white.opacity(0.5)) }
        }
        .frame(width: ChatConstants.imageBubbleWidth, height: ChatConstants.imageBubbleWidth * 1.25)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            lockOverlay
        }
    }

    @ViewBuilder
    private var lockOverlay: some View {
        switch lockStatus {
        case .locked:
            ZStack {
                Color.black.opacity(0.4)
                Image(systemName: "lock.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 3)
            }
        case .unlocked:
            Image(systemName: "lock.open.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .padding(6)
                .background(Color.black.opacity(0.35), in: Circle())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(6)
        case .unknown:
            EmptyView()
        }
    }
}

/// H-3 私密视频消息气泡（对齐同款 lock/unlock 叠图 + 播放按钮 + 时长）。
struct PrivateVideoBubbleView: View {
    let url: URL
    let coverUrl: URL?
    let dur: Int
    let lockStatus: PrivateLockStatus
    let onTapPlay: () -> Void

    var body: some View {
        Button(action: onTapPlay) {
            ZStack(alignment: .bottomTrailing) {
                thumbnailImage
                // 中心播放按钮（同 VideoBubbleView）
                Image(systemName: "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(.black.opacity(0.4))
                    .clipShape(Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                // 右下角时长
                if dur > 0 {
                    Text(formattedDuration)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(6)
                }
            }
            .frame(width: ChatConstants.imageBubbleWidth, height: ChatConstants.imageBubbleWidth * 1.25)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { lockOverlay }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let cover = coverUrl {
            CachedAsyncImage(url: cover, contentMode: .fill, persistent: true) {
                ChatPalette.cardBackground
            }
        } else {
            // 无 coverUrl（后端未返）—— 视频占位 + 大 icon（同 MediaPickerSheet.thumbnail）
            ZStack {
                ChatPalette.cardBackground
                Image(systemName: "video.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    @ViewBuilder
    private var lockOverlay: some View {
        switch lockStatus {
        case .locked:
            ZStack {
                Color.black.opacity(0.4)
                Image(systemName: "lock.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 3)
            }
        case .unlocked:
            Image(systemName: "lock.open.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .padding(6)
                .background(Color.black.opacity(0.35), in: Circle())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(6)
        case .unknown:
            EmptyView()
        }
    }

    private var formattedDuration: String {
        let m = dur / 60
        let s = dur % 60
        return String(format: "%d:%02d", m, s)
    }
}
