import SwiftUI

/// 私密媒体单元卡片（图片/视频缩略图 + 删除按钮 + 礼物价值 pill + tap 预览）。
///
/// H5 视觉参考：`components/common/c-uploadImgsAndVideos.vue`
/// - 缩略图 1:1 aspect ratio；LazyVGrid 平均分（一行 3）
/// - 底部溢出 pill：黄钻石 icon（`diamond-yellow.webp`）+ `giftPrice` 数字（`giftPrice != nil` 才显示）
/// - tap 缩略图 → `onTap` 触发预览（父层 fullScreenCover）
/// - tap 右上角 X → `onDelete`（独立按钮不吞 tap）
struct PrivateMediaCard: View {
    let item: PrivateMedia
    let onDelete: () -> Void
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                // 尺寸驱动：Color.clear 撑满 grid 分给的宽度 + 1:1 → cell 外框尺寸由父容器决定，
                // 与 image 原始尺寸无关（step 3 反悔 #8：修 scaledToFill 撑破 cell）
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        Button(action: onTap) {
                            thumbnail    // image scaledToFill 被外层 clipped 严格裁到 cell 尺寸
                        }
                        .buttonStyle(.plain)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())

                // 删除按钮（右上角）
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .padding(4)   // 扩大触摸区，避 tap 缩略图误命中
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel(L10n.GiftMessage.deleteItem)
            }

            // 底部礼物价值 pill（负 offset 让 pill 溢出到缩略图底部；对齐 H5 translate-y-1/2）
            if let price = item.giftPrice, price > 0 {
                giftPricePill(price: price)
                    .padding(.top, -10)
            } else {
                // 占位 10pt 保 cell 高度稳定（未绑不显示 pill 但布局不跳动）
                Spacer().frame(height: 10)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.giftPrice.map { "gift value \($0)" } ?? "")
    }

    /// 底部礼物价值 pill：coins + 数字（主播视角看用户送来的礼物价值,非 Party 收益）
    private func giftPricePill(price: Int) -> some View {
        HStack(spacing: 3) {
            CDNAssetImage("coins")
                .resizable()
                .frame(width: 10, height: 10)
            Text("\(price)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(Color.black.opacity(0.55))
        )
    }

    @ViewBuilder
    private var thumbnail: some View {
        if item.isVideo, let s = item.signedUrl, let url = URL(string: s) {
            ZStack {
                CachedAsyncImage(url: url,
                                 contentMode: .fill,
                                 persistent: false,
                                 cdn: (.custom(width: 800), .fill)) {
                    thumbnailPlaceholder(systemImage: "video.fill")
                }
                // 视频角标
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
        } else if let url = URL(string: item.originalUrl), !item.originalUrl.isEmpty {
            CachedAsyncImage(url: url,
                             contentMode: .fill,
                             persistent: false,
                             cdn: (.custom(width: 800), .fill)) {
                thumbnailPlaceholder(systemImage: item.isImage ? "photo" : "video.fill")
            }
        } else {
            thumbnailPlaceholder(systemImage: item.isImage ? "photo" : "video.fill")
        }
    }

    private func thumbnailPlaceholder(systemImage: String) -> some View {
        ZStack {
            Color(hex: 0x2B213E)
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.4))
        }
    }
}

#if DEBUG
#Preview("PrivateMediaCard") {
    HStack {
        PrivateMediaCard(
            item: PrivateMedia(id: "1", iconType: 1, originalUrl: "",
                               signedUrl: nil, signedAt: nil,
                               giftId: "100", giftName: "Rose", giftPrice: 100),
            onDelete: {},
            onTap: {}
        )
        PrivateMediaCard(
            item: PrivateMedia(id: "2", iconType: 2, originalUrl: "",
                               signedUrl: nil, signedAt: nil,
                               giftId: "", giftName: nil, giftPrice: nil),
            onDelete: {},
            onTap: {}
        )
    }
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
#endif
