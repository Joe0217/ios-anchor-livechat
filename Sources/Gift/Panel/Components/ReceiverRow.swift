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
        if cfg.items.isEmpty {
            // 空态占位（对齐 H5 hasRecipient=false 语义；避免用户误以为 UI bug）
            HStack {
                Spacer()
                Text(L10n.giftPickerRecipientsEmpty)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        } else {
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
            .padding(.vertical, 4)  // 高度压缩：10 → 4
        }
    }

    /// PA-4（对齐 H5 party-gift-popup.vue L921-925 avator-num）：头像下方叠麦位序号胶囊。
    /// H5 seatIndex 1-indexed（PartyRoomSeat.stableId 注释"麦位 1-13"）；直显不转换。
    private func avatarCell(_ item: ReceiverItem) -> some View {
        let selected = store.receiversSelection.contains(item.id)
        return Button(action: { store.toggleReceiver(item.id) }) {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    AvatarView(url: item.avatarURL, size: 34, kind: .user, persistent: false)
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
                // 麦位序号胶囊（重叠在头像底部；nil 时隐藏留白等宽）
                if let idx = item.seatIndex {
                    Text("\(idx)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.black.opacity(0.5)))
                        .offset(y: -6)
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
