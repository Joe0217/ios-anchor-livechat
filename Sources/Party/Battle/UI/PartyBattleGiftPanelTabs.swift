import SwiftUI

/// 送礼面板红/蓝队 Tab 切换头（对齐 H5 giftPanelTabs.vue 73 行）
///
/// **触发条件**：仅 PK RUNNING 阶段展示（挂载责任在礼物面板父容器，本组件不做条件判断）
///
/// **视觉结构**：
/// - 顶部左右并列两枚 54pt 高设计稿按钮图
/// - Red / Blue 大字白色 700 字重
/// - 选中态：完整不透明
/// - 未选中：降低透明度及缩放，点击后切换高亮
///
/// **数据流**：`team: Binding<Int>` 双向绑定，1=红 2=蓝
/// 父级礼物面板根据 team 过滤 recipientList 展示对应队伍麦位用户
struct PartyBattleGiftPanelTabs: View {
    @Binding var team: Int  // 1=红 2=蓝

    var body: some View {
        HStack(spacing: 12) {
            tabButton(label: L10n.Party.Battle.giftTabRed, value: 1, image: "partyPkGiftTabRed")
            tabButton(label: L10n.Party.Battle.giftTabBlue, value: 2, image: "partyPkGiftTabBlue")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func tabButton(label: String, value: Int, image: String) -> some View {
        let isActive = team == value
        Button {
            team = value
        } label: {
            ZStack {
                // 素材按原比例显示，不再作为裁切、铺满的按钮背景；周围露出礼物面板底色。
                CDNAssetImage(image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 54)
                Text(label)
                    .font(.subheadline).bold()
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .opacity(isActive ? 1.0 : 0.45)
            .scaleEffect(isActive ? 1.0 : 0.96)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}
