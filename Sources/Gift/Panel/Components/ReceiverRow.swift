import SwiftUI

/// 派对房受者头像行（spec §3 顶部区，config.receivers != nil 才渲染）。
///
/// 本轮：UI 完整实现（对齐设计稿 `party房-背包礼物.png` 头像 grid + All 按钮）；
/// 数据由 config.receivers 注入 mock；受者切换事件通过 store.toggleReceiver / toggleAllReceivers。
///
/// 未来（H+ 派对房送礼）：`receivers.items` 由 PartyStore.seats 派生；本 View 不依赖派对房逻辑。
struct GiftPanelReceiverRow: View {
    @ObservedObject var store: CommonGiftPanelStore

    var body: some View {
        guard let cfg = store.config.receivers else {
            return AnyView(EmptyView())
        }
        return AnyView(content(cfg: cfg))
    }

    @ViewBuilder
    private func content(cfg: ReceiversConfig) -> some View {
        HStack(spacing: 10) {
            // 计数显示（左）
            if cfg.allowMultiSelect {
                Text("\(store.receiversSelection.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(minWidth: 22)
            }

            // 头像横滑
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(cfg.items) { item in
                        avatarCell(item)
                    }
                }
                .padding(.horizontal, 2)
            }

            // All 按钮（右）
            if cfg.allowMultiSelect && cfg.showAllButton {
                allButton(cfg: cfg)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func avatarCell(_ item: ReceiverItem) -> some View {
        let selected = store.receiversSelection.contains(item.id)
        return Button(action: { store.toggleReceiver(item.id) }) {
            ZStack(alignment: .topTrailing) {
                CachedAsyncImage(url: item.avatarURL,
                                 contentMode: .fill,
                                 persistent: false,
                                 cdn: (.avatarSmall, .fill)) {
                    Circle().fill(Color.white.opacity(0.15))
                }
                .frame(width: 34, height: 34)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(selected ? Color.pink : Color.clear, lineWidth: 2)
                )

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white, Color.pink)
                        .offset(x: 2, y: -2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy)
    }

    private func allButton(cfg: ReceiversConfig) -> some View {
        let allIds = Set(cfg.items.map(\.id))
        let allSelected = !allIds.isEmpty && store.receiversSelection == allIds
        return Button(action: { store.toggleAllReceivers() }) {
            HStack(spacing: 4) {
                Text(L10n.giftPickerAll)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(allSelected ? .white : .white.opacity(0.7))
                Circle()
                    .fill(allSelected ? Color.pink : Color.white.opacity(0.15))
                    .frame(width: 16, height: 16)
                    .overlay(
                        allSelected
                            ? Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                            : nil
                    )
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy)
    }
}
