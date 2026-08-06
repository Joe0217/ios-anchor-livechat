import SwiftUI

/// K spec H5 对齐版（2026-07-02）：滤镜缩略图横滑列表（sheet 内 filter tab）。
///
/// 强度 slider 已移至父 view [BeautySettingsView](BeautySettingsView.swift) 顶部（对齐 H5 单 slider 语义）。
/// 缩略图：Q3 (a) 决策——本期 SF Symbol 占位；生产真图后 asset name = `BeautyFilterThumbnails/<key>`。
struct BeautyFilterPanel: View {
    @ObservedObject var store: BeautySettingsStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(BeautyFilterCatalog.items) { item in
                    filterCell(item)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 0)
        }
    }

    private func filterCell(_ item: BeautyFilterCatalog.Item) -> some View {
        let selected = store.settings.filterName == item.key
        return VStack(spacing: 4) {
            // 需求 3（2026-07-02）：从 H5 assets 拷贝真图到 Assets.xcassets/BeautyFilterThumbnails
            CDNAssetImage("BeautyFilterThumbnails/\(item.key)")
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(store.settings.enabled ? 1 : 0.3)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(selected ? Theme.Palette.brandPinkA : Color.clear, lineWidth: 2)
                )
            Text(item.label)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.Palette.brandPinkA : Color.white.opacity(0.75))
                .lineLimit(1)
        }
        .frame(width: 54)
        .contentShape(Rectangle())
        .onTapGesture {
            guard store.settings.enabled else { return }
            store.mutate { $0.filterName = item.key }
        }
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct BeautyFilterPanelPreviewWrapper: View {
    @StateObject var store = BeautySettingsStore(persistence: InMemoryBeautyPersistence())
    let preselectedFilter: String

    var body: some View {
        BeautyFilterPanel(store: store)
            .background(Color(hex: 0x2D1B4E))
            .onAppear {
                store.mutate { $0.filterName = preselectedFilter }
            }
    }
}

#Preview("Filter Panel") {
    BeautyFilterPanelPreviewWrapper(preselectedFilter: FilterKey.mitao1)
}
