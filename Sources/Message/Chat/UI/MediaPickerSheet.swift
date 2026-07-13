import SwiftUI

/// 主播相册选择器 sheet（H-2 spec §4.4，对齐 H5 `albumPopup.vue`）。
///
/// **视觉**：半屏 sheet 236 高、深渐变背景，横向滚动网格 88x110 圆角 8，单选 + send 按钮。
///
/// **数据源**：`AnchorInfo.pictures[]` + `AnchorInfo.videos[]` 组装为统一 `[AnchorMediaItem]`
/// （spec §2.1 词表）。
struct MediaPickerSheet: View {
    let items: [AnchorMediaItem]
    let isLoading: Bool
    /// 私密相册模式：cell 右下叠加锁 icon 区分（对齐 H5 albumPopup type=2 `album-lock.png`）
    var showLockIcon: Bool = false
    /// 用户选中并 tap send 时回调
    let onSend: (AnchorMediaItem) -> Void
    /// 用户 dismiss（tap 遮罩 or 拉下）
    let onDismiss: () -> Void

    @State private var selectedId: String?
    /// H-3 v4 (2026-07-08)：加载超时兜底 —— 8s 后仍 isLoading==true 显示 empty state 而非永久转圈
    @State private var loadingTimedOut: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            // 顶部 handle
            Capsule()
                .fill(Color.white.opacity(0.3))
                .frame(width: 32, height: 4)
                .padding(.top, 6)

            // 网格
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 底部 send 按钮
            sendButton
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .frame(height: 280)
        .background(ChatPalette.navGradient)
        .task {
            // 8s 兜底：AnchorInfoStore.mine 永久 nil（接口失败 / 未触发）时不永久转圈
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if isLoading { loadingTimedOut = true }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && !loadingTimedOut {
            skeleton
        } else if items.isEmpty {
            emptyState
        } else {
            grid
        }
    }

    private var skeleton: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(0..<5, id: \.self) { _ in
                    ChatPalette.cardBackground
                        .frame(width: 88, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay { ProgressView().tint(.white.opacity(0.4)) }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var emptyState: some View {
        EmptyStateView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(items) { item in
                    mediaCell(item)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func mediaCell(_ item: AnchorMediaItem) -> some View {
        Button {
            selectedId = item.id
        } label: {
            // 统一固定尺寸 88x110 的 cell —— 所有 overlay 用 frame(alignment:) 自控位置,不依赖 ZStack alignment
            ZStack {
                thumbnail(item)
                    .frame(width: 88, height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // 左上：图/视频类型 icon（对齐 H5 albumPopup album-image.webp / album-video.webp）
                typeIconBadge(item)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                // 右上：选中标记
                selectionMark(isSelected: selectedId == item.id)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                // 右下：视频时长（仅视频且有 dur）
                if item.kind == .video, let dur = item.dur {
                    videoDurationBadge(dur: dur)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }

                // 左下：私密相册 giftPrice 徽章（Batch 4，对齐 H5 albumPopup 私密项显示解锁价）
                if showLockIcon, let price = item.giftPrice, price > 0 {
                    giftPriceBadge(price: price)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }

                // 中心：私密锁 icon（H5 albumPopup type=2 album-lock.png）
                if showLockIcon {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: 88, height: 110)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // S-7:a11y 让 VoiceOver 念"图片"/"视频"而非"按钮"
        .accessibilityLabel(item.kind == .video ? L10n.chatA11yMediaVideo : L10n.chatA11yMediaImage)
    }

    /// 左上角图/视频类型徽章（对齐 H5 `absolute left-6 top-6 h-16 w-16` album-image/album-video icon）
    private func typeIconBadge(_ item: AnchorMediaItem) -> some View {
        Image(systemName: item.kind == .video ? "video.fill" : "photo.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(.black.opacity(0.5), in: Circle())
    }

    @ViewBuilder
    private func thumbnail(_ item: AnchorMediaItem) -> some View {
        // Batch 4：视频无 coverUrl 时走 VideoThumbnailImage 异步提取首帧（AVAssetImageGenerator + 内存 cache）
        // 加载中/失败 → 视频占位（灰底 + 大 video icon）
        if item.kind == .video && item.coverUrl == nil {
            VideoThumbnailImage(url: item.mediaUrl) {
                ZStack {
                    ChatPalette.cardBackground
                    Image(systemName: "video.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        } else {
            let url = item.coverUrl ?? item.mediaUrl
            CachedAsyncImage(url: url, contentMode: .fill, persistent: true) {
                ChatPalette.cardBackground
            }
        }
    }

    /// Batch 4：giftPrice 徽章（私密相册 cell 左下角显解锁钻石价）
    private func giftPriceBadge(price: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "diamond.fill")
                .font(.system(size: 8))
                .foregroundStyle(Color(hex: 0x66CCFF))
            Text("\(price)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(.black.opacity(0.6), in: Capsule())
    }

    private func selectionMark(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.5))
                .frame(width: 16, height: 16)
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1)
                }
            if isSelected {
                Circle()
                    .fill(ChatPalette.primaryGradient)
                    .frame(width: 12, height: 12)
            }
        }
    }

    private func videoDurationBadge(dur: Int) -> some View {
        Text(String(format: "%d:%02d", dur / 60, dur % 60))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
    }

    private var sendButton: some View {
        Button {
            if let id = selectedId, let item = items.first(where: { $0.id == id }) {
                onSend(item)
            }
        } label: {
            Text("Send")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(selectedId == nil
                            ? AnyShapeStyle(Color.gray.opacity(0.3))
                            : AnyShapeStyle(ChatPalette.primaryGradient))
                .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(selectedId == nil)
    }
}
