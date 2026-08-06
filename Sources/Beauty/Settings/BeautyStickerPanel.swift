import SwiftUI

/// K 需求 4（2026-07-02）：贴纸 tab。
///
/// 数据源：store.settings.stickerId（`nil` = 无贴纸）
/// SDK 加载：走 Sharer/renderer.apply 广播路径统一处理（`FUBeautyRenderer.apply` 内含防抖）
/// - 用户点某贴纸 → store.mutate 改 stickerId
/// - store.$settings publisher fire → BeautySettingsView.onReceive throttle 60ms → renderer.apply
/// - FUBeautyRenderer.apply 内 lastStickerId != 新值 → 调 FUManager.loadSticker
///
/// 首位 × 清除 = stickerId = nil（同 Recover 视觉一致）
struct BeautyStickerPanel: View {
    @ObservedObject var store: BeautySettingsStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 18) {
                clearCell
                ForEach(BeautyStickerCatalog.items) { item in
                    stickerCell(item)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 0)
        }
    }

    // MARK: - × 清除首位

    private var clearCell: some View {
        let selected = store.settings.stickerId == nil
        return Button {
            store.mutate { $0.stickerId = nil }
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .stroke(selected ? Theme.Palette.brandPinkA : Color.white.opacity(0.35),
                            lineWidth: selected ? 2 : 1.2)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "xmark")
                            .font(.system(size: 18))
                            .foregroundStyle(selected ? Theme.Palette.brandPinkA : Color.white.opacity(0.85))
                    )
                Text(L10n.BeautySettings.recover)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.Palette.brandPinkA : Color.white.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 54)
            .contentShape(Rectangle())  // 用户反馈：热区覆盖全 cell（否则 .plain 只在 pixel 上响应）
        }
        .buttonStyle(.plain)
    }

    // MARK: - 贴纸 cell

    private func stickerCell(_ item: BeautyStickerCatalog.Item) -> some View {
        let selected = store.settings.stickerId == item.id
        return Button {
            guard store.settings.enabled else { return }
            store.mutate { $0.stickerId = item.id }
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .stroke(selected ? Theme.Palette.brandPinkA : Color.white.opacity(0.35),
                            lineWidth: selected ? 2 : 1.2)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: item.iconSymbol)
                            .font(.system(size: 18))
                            .foregroundStyle(selected ? Theme.Palette.brandPinkA : Color.white.opacity(0.85))
                    )
                Text(item.label)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.Palette.brandPinkA : Color.white.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 54)
            .contentShape(Rectangle())  // 热区覆盖全 cell
        }
        .buttonStyle(.plain)
    }
}

private struct BeautyStickerPanelPreviewWrapper: View {
    @StateObject var store = BeautySettingsStore(persistence: InMemoryBeautyPersistence())
    var body: some View {
        BeautyStickerPanel(store: store)
            .background(Color(hex: 0x2D1B4E))
    }
}

#Preview("Sticker Panel") {
    BeautyStickerPanelPreviewWrapper()
}
