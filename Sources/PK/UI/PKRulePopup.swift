import SwiftUI

/// B-11 · PK 规则弹窗（对齐 H5 `pkRulePopup.vue`）。
///
/// 本期为**视觉占位**——H5 侧含长文规则、图示、agree checkbox 等复杂内容；iOS 侧规则数据尚未从
/// 后端拉取，先做「Coming soon」占位。触发入口：PKInvitedSheet 顶部规则问号按钮 + 未来的 PK 设置菜单。
struct PKRulePopup: View {
    @Binding var isPresented: Bool

    var body: some View {
        PKPopupCard(isPresented: $isPresented, title: L10n.PK.ruleTitle) {
            VStack(spacing: 24) {
                Image(systemName: "book.closed.fill")
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
