import SwiftUI

/// B-10 · PK 记录弹窗（对齐 H5 `pkHistoryPopup.vue`）。
///
/// 本期为**视觉占位**——H5 侧含分页列表、时间轴、对战详情等；iOS 侧 PKService 暂无 history 接口，
/// 先做「Coming soon」占位。未来 PK 设置菜单接入后此 popup 会显示历史 PK 记录列表。
struct PKHistoryPopup: View {
    @Binding var isPresented: Bool

    var body: some View {
        PKPopupCard(isPresented: $isPresented, title: L10n.PK.historyTitle) {
            VStack(spacing: 24) {
                Image(systemName: "clock.arrow.circlepath")
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
