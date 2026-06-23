import SwiftUI

/// Profile 自我介绍区。bio 为空时整段不渲染（不显示假占位文案）。
struct ProfileBioView: View {
    let bio: String

    @ViewBuilder
    var body: some View {
        if !bio.isEmpty {
            Text(bio)
                .font(Theme.Typography.profileDesc)
                .foregroundColor(Theme.Palette.profileDesc)
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
                .lineLimit(6)  // 防止接入接口后超长 bio 把页面撑爆
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Metric.profileDescPadding)
        }
    }
}
