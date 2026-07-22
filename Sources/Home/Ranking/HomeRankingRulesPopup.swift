import SwiftUI

/// H5 `CThemePopup` 对齐：居中遮罩、不可点遮罩关闭、紫色规则卡和渐变确认按钮。
struct HomeRankingRulesPopup: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.58).ignoresSafeArea()
            VStack(spacing: 20) {
                Text(L10n.homeRankRules)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                Text(text)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.76))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onDismiss) {
                    Text(L10n.commonOK)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            LinearGradient(colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)], startPoint: .leading, endPoint: .trailing),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(28)
            .frame(maxWidth: 334)
            .background(Color(hex: 0x5300A1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 20)
        }
    }
}
