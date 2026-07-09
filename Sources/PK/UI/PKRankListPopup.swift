import SwiftUI

/// B-12 · PK 排行榜弹窗（对齐 H5 `pkRankListPopup.vue`）。
///
/// 本期为**视觉占位**——H5 侧含全服/好友/周榜 tab、分页、跳转个人页等交互；iOS 侧 PKService 暂无
/// ranking 接口，先做「Coming soon」占位。未来 PK 设置菜单接入后此 popup 会显示 PK 排行榜。
struct PKRankListPopup: View {
    @Binding var isPresented: Bool

    var body: some View {
        PKPopupCard(isPresented: $isPresented, title: L10n.PK.rankTitle) {
            VStack(spacing: 24) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.top, 8)
                Text(L10n.PK.comingSoon)
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.85))
                Spacer().frame(height: 8)
            }
        }
    }
}
