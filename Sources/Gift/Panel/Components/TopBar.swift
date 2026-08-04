import SwiftUI

/// 面板顶部条：tab 切换（多 tab 时）· Backpack icon（config.backpack=.visible 时）。
///
/// spec §3 UI 结构：位于 receivers 行下方（若有）、grid 上方。
///
/// **v2 修订（2026-07-09）**：删除左上 × 关闭按钮 —— 用户反馈 "顶部按钮误触"。
/// dismiss 靠 sheet 下滑手势（`.presentationDragIndicator(.visible)` 提示；`.hidden` 场景仍能 swipe-down 关）。
struct GiftPanelTopBar: View {
    @ObservedObject var store: CommonGiftPanelStore

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // 左：tab 切换（config.tabs.count > 1 才渲染）
            if store.config.tabs.count > 1 {
                HStack(spacing: 20) {
                    ForEach(store.config.tabs, id: \.self) { tab in
                        tabButton(tab)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let title = store.config.title {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }

            // 右：Backpack icon（切图 pink 圆形已烘 alpha 通道，不用 template render）
            if case .visible = store.config.backpack {
                Button(action: { store.triggerBackpack() }) {
                    CDNAssetImage("ic_backpack")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func tabButton(_ tab: GiftPanelTab) -> some View {
        let isActive = store.currentTab == tab
        return Button(action: { store.switchTab(tab) }) {
            VStack(spacing: 4) {
                Text(tab.displayName)
                    .font(.system(size: 14, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? .white : .white.opacity(0.55))
                    .lineLimit(1)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isActive ? Color.pink : Color.clear)
                    .frame(height: 3)
                    .frame(maxWidth: 24)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy)
    }
}
