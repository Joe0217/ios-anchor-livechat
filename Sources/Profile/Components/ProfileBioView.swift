import SwiftUI

/// Profile 描述行（"✨ Your Starry Guide ..."）。
struct ProfileBioView: View {
    let bio: String

    var body: some View {
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
