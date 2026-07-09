import SwiftUI

/// 视频消息气泡（H-2 spec §1 表 1.3，对齐 H5 `msgItem.vue:243-254`）。
///
/// **视觉**：thumbnail（同图片规范 100x125）+ 中心 48 圆形白色播放按钮 + 右下角时长 badge。
/// tap 触发全屏播放（H-2 只做骨架，播放器接线延到 step 2）。
struct VideoBubbleView: View {
    let thumbnailUrl: URL?
    let dur: Int
    let onTapPlay: () -> Void

    var body: some View {
        Button(action: onTapPlay) {
            ZStack(alignment: .bottomTrailing) {
                thumbnailImage
                // 中心播放按钮
                playButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                // 右下角时长 badge
                Text(formattedDuration)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(6)
            }
            .frame(width: ChatConstants.imageBubbleWidth, height: ChatConstants.imageBubbleWidth * 1.25)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())   // 按 swiftui-button-plain-hitarea 规则
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let url = thumbnailUrl {
            CachedAsyncImage(url: url, contentMode: .fill, persistent: true) {
                ChatPalette.cardBackground
            }
        } else {
            ChatPalette.cardBackground
        }
    }

    private var playButton: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background(.black.opacity(0.4))
            .clipShape(Circle())
    }

    private var formattedDuration: String {
        let m = dur / 60
        let s = dur % 60
        return String(format: "%d:%02d", m, s)
    }
}
